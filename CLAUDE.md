# CLAUDE.md — Claude-specific overlay

`AGENTS.md` is the shared baseline (project, safety rules, layout, tests, conventions, review and
merge policy). This file only adds Claude-specific bits. Where the two overlap, AGENTS.md wins.

## Model, in one line

The latest Opus is the default for direct work in the main thread. Subagents default to the latest
Sonnet (routine implementation, tests) or Haiku (exploration, deploy). Always the newest version of
each family; don't pin a version number here.

## The one rule that is easy to forget

**Never merge a PR without the owner's explicit approval.** `gh pr merge` is not yours to run on
your own judgment, however green the checks are.

## Adversarial review — prefer a *different* family

For a second opinion on a plan, design or diff, the value is decorrelated blind spots:

1. **First choice: Codex** via `/codex-consult` (`.claude/skills/codex-consult`). Also the PR-review
   step in `docs/WORKFLOW.md`.
2. **Fallback when Codex is unavailable:** Fable. Same family, weaker adversary — lean on its long
   context.
3. **Stay in the main thread** when the question is really about this codebase's specifics (below).

Loop: Claude drafts → Codex attacks → Claude reconciles. Take its bug-catching seriously; be
skeptical when a cold model ratchets complexity outside the safety rules. It is a reviewer, not an
oracle — the plan review that founded this repo had one suggestion (a restricted Lua parser in
PowerShell) we replaced with something simpler and testable.

### This codebase's specifics (feed these to any external reviewer)

- **The safety rules in AGENTS.md** and the adaptive-load vs exact-restore split in `docs/DESIGN.md`.
- **Manual Load/Save/Save As only.** No event, login or sync receipt ever writes game state (the
  trigger/write matrix in `docs/DESIGN.md`). A reviewer proposing "auto-apply when…" is proposing
  the design the owner rejected on 2026-10-08.
- **Forever, not Classic/TBC.** Vanilla content on the Mainline client; many Classic globals are
  gone (`PickupSpell`, `GetSpellInfo`, `MAX_ACCOUNT_MACROS`, `EasyMenu`…). Use what the API dump in
  `C:\Projects\References` declares and `docs/forever-api-notes.md` measures.
- **No StaticPopups**, measured to taint.
- **SavedVariables shape** — there is real data on disk once M1 ships; a shape change needs a schema
  bump and a test, and the addon refuses newer schemas.
- **LibAccountSync cannot cross flavours** (by design); beta → live is a file copy of
  `AltStableSync.lua` only. The LAS store lives in the separate `AltStableSyncLink` addon's file so
  it never travels. Catalog sync uses version ancestry (`writer:seq` + `parent`), not numbers.

## Fable usage

Fable for adversarial critique only as the Codex fallback, for post-phase diff review, and for
large multi-file refactors. Never single-file work. Implementation use needs explicit per-turn
owner approval.
