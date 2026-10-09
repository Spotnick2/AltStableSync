# Acceptance scenarios

> From the 2026-10-08 pivot handoff, verbatim except this header (which replaces its intro) and A26, A39, A41 and A44
> (tightened to the design's rules). These are **requirements, not
> passed tests**. Automate pure planning and state logic against Forever-shaped stubs; run client
> behaviour in game. "Persists" always means a **full client exit and relaunch**, never `/reload`.
> The design of record is `docs/DESIGN.md`; where they differ, DESIGN.md wins.

| ID | Scenario | Required result |
|---|---|---|
| A01 | Save Priest / Discipline / Everyday, then select Holy | Separate list; switching picker changes no game state |
| A02 | Load Everyday on a second priest | Own-frame preview, backup first, verified permitted writes |
| A03 | Drag a button, log out, log in | Shared preset unchanged; no automatic reload of saved layout |
| A04 | Change a macro on the low-level priest and explicitly Save | Shared entry updates; other priest runtime unchanged until explicit Load |
| A05 | Save As Dungeon healing | New stable ID; original entry and other characters unchanged |
| A06 | Save As blank, whitespace, or duplicate name | Inline error in same category; matching name in another category allowed |
| A07 | Load future spell into a low-level alt whose destination contains food | Spell retained in preset; food slot emptied (#46), listed with the reason, back with Restore; result counts it as emptied |
| A08 | Save that low-level alt without changing the skipped destination | Future spell retained, not replaced by food or empty capture |
| A09 | Save As on that low-level alt | Fork retains unavailable inherited spell and original rank policy |
| A10 | Highest-known policy loads Rank 2 on low alt; alt saves | Policy remains highest-known; higher alt later gets highest known rank |
| A11 | Deliberate Rank 1 spell in loadout | Exact/downrank intent survives load and save; restore never upgrades |
| A12 | Two candidate spell families or unsupported locale mapping | Defer visibly; do not guess using same display name alone |
| A13 | Foreign racial, missing item or unlearned spell | Resolvable entries are placed; the rest empty their slot, each with its reason (#46); a failed read leaves the slot untouched |
| A13b | Slot empty in the loadout (inside its cover) holds something on this character | Emptied, listed in the preview, back with Restore (#46); outside the cover it is never touched |
| A14 | Learn a previously skipped spell | Availability may update; no writes until explicit Load/Retry with new preview |
| A15 | Macro action reports a spell ID as action ID | Captured macro is correct by name/guarded index resolution |
| A16 | Duplicate macro names across scopes | Resolve identity correctly or defer; never edit an account macro |
| A17 | Macro body gains server trailing newline after full exit | Comparison recognizes documented normalization without altering body semantics |
| A18 | Macro capacity full or Include character macros unchecked | Missing dependency shown before writes; no unrelated deletion or wrong button |
| A19 | Macro contains a currently unlearned spell | If macro exists/created and placement is supported, place it; verify in game |
| A20 | Character uses Account bindings; destination is Character | No automatic set switch; block/exclude safely and explain manual step |
| A21 | A command has two keys and loadout displaces one | Preview displacement; read back both keys; exact restore recovers them |
| A22 | Combat starts partway through apply | Stop further protected writes; retained result; manual re-preview to resume |
| A23 | Cursor occupied before capture/apply | Refuse cursor-mutating work without touching payload |
| A24 | Backup capture fails | Zero game-state writes |
| A25 | Write read-back differs | Failure/partial report, no false success; original backup remains usable |
| A26 | Restore after adaptive load | New backup first; original exact rank/keys/macros restored within supported scope; macros that load created are offered for removal, including after the load completed or was abandoned and the client was fully exited |
| A27 | Exact snapshot value no longer exists | Report partial/unavailable; never adaptive substitution |
| A28 | First UPDATE_MACROS contains account macros only | Capture/apply remains gated until measured readiness checks succeed |
| A29 | Unknown/newer saved schema | Refuse with no rewrite, reset or best-effort parse |
| A30 | Druid changes Bear/Cat/normal form | No catalog Save; mapped underlying pages remain separate where actually independent |
| A31 | Druid loadout loaded while in a different form | Active and inactive supported pages captured/planned correctly; no potion/form-page corruption |
| A32 | No UI presets on first character | Honest empty state and Save this character's UI; no nonexistent default |
| A33 | New alt declines initialization | No writes; dismissal remembered; main panel remains usable |
| A34 | Apply My UI with unsupported addon provider | Clear skipped status; supported subset applied only after preview |
| A35 | Save from character missing a previously included addon | Saved provider payload preserved, not erased |
| A36 | Apply account-scoped CVar / shared native layout | Preview accurately states physical scope; protected shared layout handled by reviewed policy |
| A37 | Edit Mode initialize then restore, full exit and relaunch | Correct active layout/content persists; no reliance on reordered numeric list indices |
| A38 | Saved entry changes between preview and confirm | Reject stale plan, recompute and re-preview |
| A39 | Save from older loaded revision over newer catalog version | No silent loss; Save As, or a refreshed Load then Save |
| A40 | Import/receive catalog later | No current character mutation; only deliberate Load applies it |
| A41 | Beta carryover with nonempty LAS | Transfer refuses an `AltStableSync.lua` that assigns a value to `AltStableSyncLAS` (`= nil`, which the client writes for a declared-but-unset variable, is fine); otherwise copies only that file and leaves both Link stores (`AltStableSyncLink.lua`) untouched. A separate, nonempty Link store does not block transfer. LAS never crosses flavors |
| A42 | Beta build/project ID changes normally | No false flavor migration or destructive catalog reset |
| A43 | Full exit after bars/macros/bindings apply and restore | Compare exact captured values; `/reload` alone is not accepted as persistence proof |
| A44 | Saved entry replacement was a mistake | Previous saved version recoverable separately from runtime backup while the current version is still the one produced by that Save |
| A45 | Restore after account macro was externally changed | No account write; accurate unavailable dependency/partial outcome |

## Minimal launch rehearsal

1. On a prepared character, save My UI and a category loadout. Capture an independent before-state record.
2. On a lower-level same-class character, initialize the supported UI subset and load the loadout. Inspect preview counts and skipped future/racial actions.
3. Change one character macro and one resolvable action. Save As. Verify inherited unavailable entries remain and the original entry is unchanged.
4. Load the new entry on the original character only after choosing to. Verify ranks, bindings and macro identity.
5. Interrupt a controlled apply; review remaining work; restore the earlier exact snapshot. Confirm another pre-restore backup exists.
6. Repeat form-page tests on a druid, including inactive forms and a common utility action.
7. Fully exit the client, relaunch, and compare. Record client build, class/race/faction, levels, steps, observed values and failures.
8. Rehearse the explicit-path transfer on a clean destination without LAS. First target login must offer a choice, never mutate automatically.

Keep results next to the runbook/probe evidence. Passing the HTML concept or pure planner tests does not satisfy these in-game gates.
