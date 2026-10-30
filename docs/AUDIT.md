# Audit: does the preview match the apply, and does restore really restore?

Issue #95, branch `audit/preview-restore`, on `main` after the v1.0.0 release notes (#94); launch
2026-11-04. The question
audited, as one property: **the state after Load/Apply equals the state the preview described, and
the state after Restore equals the state before the operation, within a declared scope, with every
exception named in the preview or the report.** The plan was reviewed with Codex gpt-6-astra (high)
in three rounds to consensus (2026-10-29/30); `docs/DESIGN.md` "Review record" has the summary.

Facts met on the way, not fixed here:
- **Build 70532 exists** (`References\Forever\api`, the `wow-ui-source` clone); `MEASURED_ON_BUILD` is
  70450. The in-game checks below run on 70532. The bump is the `client-update` skill's job.
- **Action-bar toggles are a server-mirrored mask.** Blizzard's Settings code
  (`wow-ui-source/Interface/AddOns/Blizzard_SettingsDefinitions_Frame/ActionBars.lua:13-24`, 70532)
  caches it for 10 s because the client "will send an outdated mask to the server and clear out values
  that were just set". `UISetup.WriteBars` reads back the client cache, not the server.

## 1. Trace matrix

Per part: what the preview says, what Execute writes, what the backup holds, what Restore replays,
and the **declared exceptions**: what a restore knowingly leaves and where that is said. A cell that
says more or less than its row's others was a finding (section 2) or is a declared exception here.

| Part | Preview | Write | Backup | Restore | Declared exceptions (where said) |
|---|---|---|---|---|---|
| Action slots 1-120, 145-180 | `Commands.Describe`: one line per slot in `plan.actions` ("was -> now", with the loadout's action and reason when a slot is emptied), `skips` as "left unchanged", `waiting` as "stays empty until…" | `Loadout` `Execute` step 2: pick up, place, verify the displaced payload against the snapshot, clear it, read back | `Snapshot`: `actions[slot]` for every planned slot, `false` for empty; refused if any planned slot isn't restorable | `PlanRestore`: exact ids; a value no longer available → `unavailable`, listed "can't be restored exactly" | A covered-**empty** slot holding something the backup can't put back is left as it is: listed "left unchanged" (D12; was unlisted) |
| Character macros: create | `MacroLines` "N macros to create" | step 1 `CreateMacro`, read back by name | `createdMacros` (journaled as soon as the macro exists, D10; shared with `firstSeen`, D7) | never deleted (safety rule 5, #6 deferred): listed **by name** as kept (D14) | created macros stay (restore preview and report) |
| Character macros: update | `MacroLines`: name, "text changes" with the first differing line, "icon changes"; "An updated macro changes every button that uses it, on any bar" | step 1b `EditMacro` after re-checking the macro is as previewed, read back | `editedMacros` before/after, written before the pin | reverted when the macro is still as the load left it; left and listed when it changed since or is gone | a macro matching neither before nor after: listed "changed since the load, left as is" |
| Keys `ACTIONBUTTON1-12`, `BONUSACTIONBUTTON1-10` | "Bindings (Destination: Character): N keys change", one line per key "key: from -> to", **plus the save line** (D3) | step 3: `SetBinding` per key, read back, `SaveBindings(Character)`, read back again | `snap.keys[key] = command or false` for `plan.keys` only | `plan.keys` from the snapshot, same discipline | **`SaveBindings` persists the whole in-memory map**, other addons' unsaved keys included; the snapshot can't undo that (D3: said in every preview that saves). Under Account bindings the key part is blocked and listed; a restore then stays partial |
| Pet bar | `PetLines`: per changed pet slot "from -> to", skips, other families kept | `Pet.Execute`: moves, swaps, removals, placements from the book, each read back; a payload never cleared on failure | `Pet.Snapshot`: the ten slots of the pet out (same GUID) | `Pet.PlanRestore`: exact ids, only with the same pet (family + name) out; else "needs X out", partial | autocast is an invariant (never written; preview says so). Another pet out → listed, partial |
| Layout selection | "Layout: A -> B" (+ "the layout itself isn't changed") | `SetActiveLayout` by index found by type + name, read back | `snap.layout` type/name (index for presets) | by type + name again | a layout deleted or renamed since → "Can't be restored", listed |
| Bars 2-8 | per bar "show"/"hide" + "change after a reload" | `SetActionBarToggles` all seven, read back | `ReadBars()` | same | server persistence and a layout's own Visible setting: **unmeasured** (H6, in game) |
| CVars (allowlist) | "X: a -> b (affects this WoW account)" | `SetCVar`, read back | values | same | account scope: said in both directions |
| Chat | "Main chat window: add …", "New chat tab …" | `SetGroups` add then remove, **guarded before every call** (D4), whole-window check after; `CreateTab` | windows touched + `creating` names | exact per window, add before remove, read back | created tabs kept and selected (listed in the restore preview); a group the client doesn't know → window left alone, listed |
| Damage meter | `DamageMeter.Describe` per window, the window-2 line, **the undo line** (D6) | manager setters, read back; `Show` with an ownership journal | windows 1-2 + `journal` (shared with `firstSeen`) | `M.Plan(snap, true)`: whole part or nothing | on Forever (no `IsUserPlaced`) a window 2 the apply opened can't be hidden, so **the whole meter part** stays as applied: said at apply (D6) and at restore ("Can't be restored: Damage meter …", partial) |
| Backup lifecycle | "Abandon the incomplete load of X? Its backup stays in your backups." | `Snapshot` → `Backups.Pin` → first write; `Release` on completion; a restore's own snapshot `PushRing`, **checked** (D1) | `operation` (pinned), `ring` (10, newest first), `firstSeen` (forever) | `Commands.restore` and `Panel.SlotOf` dispatch by kind and by snapshot identity | there is no resume; abandon moves the pin into the ring (D11, doc). `firstSeen` shares the created-macro journal (D7) |
| Plumbing | `Preview.Show` keeps the plan in the confirm closure | confirm re-plans and compares the fingerprint (Loadout: `Finish`, now with `kept`, D8; UISetup: the whole plan) | | | a stale preview is refused and re-shown, never applied |

Save after a restore is refused for both kinds (`tests/test_loadout.lua` "A restore since the load
removes the comparison"; `tests/test_uisetup.lua` "save after restore: refused").

## 2. Findings and fixes

Read first, confirmed by a test that fails with the fix reverted ("witness"). Lines are as of this
branch.

| # | Finding | Fix | Witness (reverted → red) |
|---|---|---|---|
| D1 | `Loadout.Restore` ignored `Backups.PushRing`'s return: a restore whose own backup couldn't be stored (no GUID) still wrote. The UI restore checked it | check it, refuse with the store's reason | `test_loadout` "D1: refused", "D1: nothing written", "D1 op: the pin is still there" (6 checks) |
| D2 | `Execute`'s `call()` discarded a `false` return: `SaveBindings` (and `SetBinding`) refusing counted as success, `bindingsUnsaved` was cleared, the load reported done | `ret == false` is a failure (nil stays success); the existing rollback runs | "D2: stopped at the bindings", "D2: keys back in memory", "D2: backup pinned" (4) |
| D3 | `SaveBindings(Character)` persists the whole in-memory key map, not just `plan.keys`, and the snapshot can't undo that; a `resave`-only load previewed as "0 keys change" and said nothing about saving | one preview line whenever a save will run; a zero-key wording for `resave`. Disclosure, not a rollback of a map we never read | "D3: a key plan says the whole map is saved", "D3: and the save is said" (2) |
| D4 | `SetGroups` added/removed several groups and `CreateTab` opened then wrote with one guard per window: combat between two groups didn't stop the operation (safety rule 7) | `Guard()` before every `ChatFrame_*MessageGroup` call | `test_uisetup` "D4 add/remove/create: stopped by combat" + "D5 …: nothing attempted in combat" (6) |
| D5 | `tests/wow_ui.lua` recorded calls without a combat check: a UI write in combat passed silently | the stub raises and records `WoW.game.blocked` in combat, as `wow_game.lua`'s `mutate` does | with D4 and D5 both reverted, 7 red: the second write happens |
| D6 | Opening meter window 2 on Forever (no `IsUserPlaced`) makes `M.Plan(snap, true)` refuse the **whole meter part**, so a restore leaves window 1's changes too; the apply preview said "Show/configure window 2" and nothing else | `M.Plan` flags it; `UISetup.Describe` adds "On this build a restore leaves the damage meter as this apply sets it: the opened window can't be hidden again." The three Forever outcomes are tested apart: window 2 absent (this), existing hidden (apply skips the part), existing shown (restores normally) | `test_damage_meter` "D6 forever: preview says the restore leaves the meter as set" (1); the whole-part oracle "window 1 keeps the applied lock/session" passes with and without the flag, as it documents behaviour |
| D7 | `Backups.First` deep-copied the snapshot at `Pin`; `createdMacros` was appended afterwards, so the first backup never listed kept macros | share `createdMacros` by reference, as the meter journal is | "D7: first backup journals the created macro" (1); content equality after a copy of the store (SavedVariables lose identity) is asserted too |
| D8 | The loadout fingerprint omitted `plan.kept`: a ring that shifted between preview and confirm to a snapshot differing only in kept macros passed the stale check | `kp = plan.kept` in `Finish` | "D8: refused as stale", "D8: nothing written" (3) |
| D9 | `UISetup.Apply` replaced `loaded.ui` before `Backups.Pin` could fail | `Record` after a successful pin | "D9: the previous record is still complete" (1) |
| D10 | A `CreateMacro` whose read-back differed wasn't journaled, so a macro that now exists with other text was never listed as kept | journal when one character macro of that name exists, then check the body ("macro created with other text") | "bad create: stopped" (1); stub knob `createFault = "wrong"` |
| D11 | `docs/DESIGN.md` safety rule 1 described a resume that keeps the original pin; the code has only "Abandon", which moves it into the ring | doc fixed; the code was right. Verified by review | — |
| D12 | A covered-empty slot holding something the backup can't put back was left alone and **unlisted** (by design, `docs/DESIGN.md`) | listed as "left unchanged: holds something this build can't put back, so it isn't emptied" (owner, 2026-10-30). Marked `empty` so Save's merge never treats it as a kept gap: a later edit there is saved | "#48/D12: blank slot with a flyout: listed", "in the preview", "nothing applied, one left unchanged" (3); the `empty` mark: "#48: not unavailable", "#48: the edit there is saved" (2) |
| D13 | Spell lines showed the name only: an exact-rank change read "Flash Heal -> Flash Heal" | same-name spells at different ids show the rank (`C_Spell.GetSpellSubtext`, 70532) or the id | "D13: rank from the subtext", "the id when there is no subtext" (2) |
| D14 | "Kept: 2 macros that load created" named none | names listed | "D14: the kept macro is named", "D10: the restore preview lists it as kept" (2) |

Dropped after reading (not defects):
- **Holed `bars` tables** (a synced or imported entry with a missing bar): `Catalog.GoodUIModules`
  requires all seven booleans at Create, Replace and receipt.
- **Save after a restore**: refused for both kinds, tested.
- **A macro updated in step 1b sitting in a slot being overwritten**: `expected()` compares the
  displaced payload against the updated text; regression in `tests/test_macros.lua`.
- **Stale restore selection**: `Panel.SlotOf` resolves the clicked snapshot by identity at the click;
  `Commands.restore` dispatches by kind; the fingerprint (now with `kept`) refuses a shifted ring.

Deferred on purpose, unchanged: removing created macros (#6), closing created chat tabs, a resume
that keeps the pin (abandon + ring instead), a per-window meter restore.

## 3. Declared exceptions, in one list

What a restore knowingly leaves, and where the player is told:
1. Character macros the load created: kept, named in the restore preview and report.
2. Chat tabs an apply created: kept and still selected, named in the restore preview.
3. Keys while Account bindings are active: blocked, said in the preview; the result is partial.
4. A character macro that matches neither its before nor its after text: left, named.
5. The whole damage-meter part after an apply opened window 2 on Forever: said at apply (D6) and at
   restore.
6. `SaveBindings` persisting every in-memory key, not only the planned ones: said in every preview
   that saves (D3). Our snapshot can't undo keys we never read.
7. A pet other than the backup's out: the pet part is left, said ("needs X out"), partial.
8. A covered-empty slot holding what the backup can't put back: left, listed (D12).
Invariants (never changed by us, so never restored): pet autocast; macro indices (the client sorts);
the trailing newline the server appends to macro bodies (compared normalised).

## 4. Round-trip scenarios and mutation witnesses

`tests/test_roundtrip.lua` (347 checks): deterministic rows over the stubs, each with its expected
outcome **stated by hand**, never derived from the plan. `observe()` reads every observable (slots,
macros with body and icon, keys in memory and the saved set, pet slots and autocast, layout, bar
toggles, CVars, chat windows, meter windows); `diff()` names each difference; a row passes only when
the differences are exactly the ones it lists.

| Row | What it does | Expected, by hand |
|---|---|---|
| R1 | Loadout L on a Character-bindings alt: two creates sorting before an updated macro that sits in two covered slots and one uncovered slot; an occupied slot overwritten; an empty-entry slot emptied; an item not in bags; an unlearned class spell; a flyout under an empty entry slot; an account macro reused; page-2 and stance-page slots; a two-key command losing a key; a key taken from an unmanaged command | 21 named differences after the load (the uncovered slot's macro text changes too); the preview covers every planned write; after Restore 1 exactly the two created macros remain, named as kept; `after == nil`; a restore of the restore returns to the loaded state |
| R2 | The same load from Account bindings | blocked as a whole, the #7 switch offered, zero writes, no backup |
| R3 | L's backup restored under Account bindings | actions and the macro back, keys untouched in memory and on disk, result partial, said |
| R4 | Another addon's unsaved key before the load | the preview says every in-memory change is saved; the saved set holds it afterwards; the backup doesn't; the restore leaves it (declared, D3) |
| R5 | Combat after the k-th mutating call, every k (the sweep stopped 33 loads); `CreateMacro` writes other text; `EditMacro` writes other text; `SaveBindings` refuses | after `restore op`: back to before except the macros created so far, each named; the odd `EditMacro` text leaves that macro named and the result partial with the pin kept; the refused save rolls the planned keys back in memory and leaves the saved set alone |
| R6 | Combat during the restore itself | its own backup is ring 1; restoring that returns to the loaded state |
| R7 | A bear's layout loaded on another hunter's bear | the pet bar changes exactly as stated (swap, moves, a removal; Bite stays empty since that bear lacks it); autocast travels with each ability and is never written; the restore returns the bar exactly |
| R8 | A UI setup: layout, bars, an account CVar, a group added, a tab created, meter window 1 changed and window 2 created | 11 named differences; the restore leaves the kept tab and the (hidden) window-2 frame; a restore of the restore returns to the applied state; a layout deleted between preview and confirm refuses with nothing written; on Forever's meter surface the apply preview warns and the whole meter part stays as applied (D6) |
| R9 | The store through a Lua round trip (SavedVariables lose table identity) | "first" and "1" both name the two kept macros and restore to before except them |

**Mutation witnesses.** Each break was applied, `tests/test_roundtrip.lua` run, the break reverted
(`restored: all green` after every run):

| Witness | Break | Result |
|---|---|---|
| W1 | one `SetBinding` dropped, read-backs intact | 14 red: the engine's own read-back fails the load ("bindings failed"); R1, R4 see it |
| W2 | the same, with both key read-backs removed | 1 red: R1's hand-stated key list (the load "succeeds" with a key missing) |
| W3 | the action read-back removed and the stub misplacing slot 15 | 2 red: R1's slot list, R3's restore |
| W4 | `snap.editedMacros` not written | 36 red: every restore that must put the macro back |
| W5 | a slot written outside the plan after the actions | 32 red: R1's exact list, the fault sweep's cursor check |
| D1-D14 | each fix reverted in turn | the named test of each goes red (section 2) |

Also observed while building the rows: the stub forgot a pet ability's autocast while it was off the
bar; the measured client keeps it in the spellbook (`docs/forever-api-notes.md`, 2026-10-11), so
`tests/wow_game.lua` now does too (`autocastMemory`). Without it R7's restore reported a false
autocast change.

## 5. In game (build 70532)

`/fp steps sync audit` (`Tools/AltStableSyncProbe`, deployed with `pwsh Tools/deploy-probe.ps1`; tested
end to end in `tests/test_probe_audit.lua`): one character, both kinds applied before the first full
exit, both restored by their backup's name after the relaunch, a second full exit, then the short
checks. The probe's independent record now holds the UI parts (active layout, bar toggles, the five
CVars, chat windows and the selected tab, meter windows 1-3) and the backups by reason and time
(`/fp sync backups`); its comparison takes the declared exceptions as allowances and names them as
`info`, never as `DIFF`. Each mechanical check is a step's `check`; the owner's yes/no answers gate
them (a No or a Skip makes a check unverified, never a pass).

| Step | What it proves |
|---|---|
| before → afterUI | the UI setup changed UI parts and nothing else (bars, macros, keys untouched) |
| afterUI → afterLoad | the loadout changed game state and no UI part |
| afterLoad → exit1 | everything applied persisted a full exit, bar toggles included (H6, persistence) |
| CTRL-F11 after exit1 | the key another addon set without saving was saved by our load, as the preview said (D3) |
| ask: bars on screen as the setup says | the toggles and the layout's Visible setting agree (H6, visibility) |
| afterUI → afterRestoreL | the loadout's restore is exact except the kept macros, named; UI untouched |
| before → afterRestoreU | the UI setup's restore is exact except the kept tab and, when the apply opened window 2, the meter part (D6) |
| afterRestoreU → exit2 | both restores persisted |
| a third key on button 1 | a Forever command holds three keys (H4), so a restore that rebinds before it unbinds drops nothing |
| accountBefore → accountAfter | an executed restore under Account bindings moved actions and touched no key |

Expected residual differences at exit2 against before: the created macros (named as kept), the
created tab (kept, selected), the whole meter part when window 2 was opened (D6), CTRL-F11 saved
(D3). Anything else is a finding.

Not in the procedure (a second character, optional): the meter's existing-shown and existing-hidden
window-2 cases; the 10 s toggle cache window (apply, restore within 10 s, `/reload`, full exit).

_Results: pending the owner's session; they go here and to `docs/forever-api-notes.md` "Build 70532"._
