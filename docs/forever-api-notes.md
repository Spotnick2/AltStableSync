# Forever API notes — AltStableSync

Facts **measured on the client** that this addon depends on. Declared shapes come from the dump
(`C:\Projects\References\forever-api-<version>.<build>.md`); addon-agnostic findings belong in the
canonical `C:\Projects\References\PORTING-TBC-TO-FOREVER.md`, not here.

`MEASURED_ON_BUILD` in `Core.lua` names the build this file describes: **70245**.

## Declared on 70235 (from the dump; the documented surface of 70245 is identical)

- Action bars: globals `GetActionInfo`, `PickupAction`, `PlaceAction`, `GetCursorInfo`,
  `ClearCursor`, `HasAction`; `C_ActionBar.*` (no `C_ActionBar.GetActionInfo`).
- Spells: `C_Spell.PickupSpell`, `GetSpellName`, `GetBaseSpell`, `GetOverrideSpell`;
  `C_SpellBook.FindSpellBookSlotForSpell`, `IsSpellKnown`, `IsSpellBookItemLowRank`; global
  `FindBaseSpellByID`. **No** `PickupSpell` / `GetSpellInfo` globals.
- Items: `C_Item.PickupItem`. **No** `PickupItem` global.
- Macros: `GetMacroInfo`, `GetMacroBody`, `CreateMacro`, `EditMacro`, `DeleteMacro`, `GetNumMacros`,
  `PickupMacro`. `MAX_ACCOUNT_MACROS` / `MAX_CHARACTER_MACROS` are nil; character macros start at
  121 (porting guide).
- Bindings: `GetBinding`, `SetBinding`, `SaveBindings`, `LoadBindings`, `GetCurrentBindingSet`,
  `Enum.BindingSet {Default, Account, Character, Current}`, `C_KeyBindings.GetBindingContextForAction`.
- `C_EditMode.GetLayouts` / `SaveLayouts` / `ConvertLayoutInfoToString` / `ConvertStringToLayoutInfo`
  / `OnLayoutAdded`.
- `C_EncodingUtil.SerializeCBOR` / `CompressString` / `EncodeBase64` (and inverses).
- `C_SpecializationInfo.*`, `C_ClassTalents.*` exist — whether they return Vanilla data is unknown.

## Measured elsewhere (cited, not re-probed)

The table in issue #2 has the details and sources. The short version:
- there is one spec per class;
- talents are in `C_Traits`;
- ranks are separate spell IDs and separate spellbook items;
- character macros start at 121;
- Edit Mode layouts are ordered presets, then Account, then Character;
- SavedVariables persist since 70009.

## Build 1.60.1.70245 (2026-10-06) - probe #2 run, one hunter

These were measured with `Tools/AltStableSyncProbe` (`/syncprobe`, PR #25). The macro, CVar and binding markers were armed one after another, then there was **one full client exit**, then `/syncprobe restart`. Both load counters went up by exactly one, which confirms that.

### Identity
- `GetBuildInfo()` returned `"1.60.1", "70245", "Oct  5 2026", 16001, "", " "`.
- `WOW_PROJECT_ID` = **18**, `WOW_PROJECT_MAINLINE` = 1, `GetCurrentRegion()` = 90, `GetCurrentRegionName()` = `""`.
  - **Consequence for #11:** never use the project ID as a flavour key. It changed between beta builds.
- `GetNumSpecGroups()` = 1 and `GetActiveSpecGroup()` = 1, so there is **no dual spec**. Profiles stay keyed by class plus a user-chosen name.

### Action slots
| Slot holds | `GetActionInfo` returns | Notes |
|---|---|---|
| Spell | `"spell", spellID, "spell"` | `C_ActionBar.GetSpell(slot)` gives the same rank-specific ID |
| Item | `"item", itemID` (2 returns) | |
| Empty | nothing | |
| Macro | `"macro", 75, "spell"` | `GetMacroInfo(75)` returns nothing |

- **For a macro, the id is the spell the macro shows**, not the macro's index: 75 is Auto Shot. `GetActionText(slot)` returns the macro's **name** (`"AuS"`).
  - **Consequence:** capture cannot identify a macro slot by its id. A macro whose spell is not learned yet (owner's point) may not report a spell id at all. The follow-up `/run` lines in #25 measure this.
- **Macros never wait on a spell.** A macro is placed whether or not its spell is learned; it shows "?" until it is. So applying a profile must never defer a macro slot because a spell is unlearned. Only spell slots and item slots are deferred.
- Count on one hunter, slots 1–200: 150 empty, 33 spell, 13 item, 4 macro.

### Placing from addon code (out of combat)
1. `C_Spell.PickupSpell(2973)` (Raptor Strike **Rank 1**, a low rank) put `"spell", 25, "spell", 2973, nil` on the cursor.
2. `PlaceAction(6)` on an empty slot emptied the cursor. The slot read back `"spell", 2973`: **an explicit low rank stays low**.
3. `PickupAction(6)` lifted it back, and `ClearCursor()` emptied the slot.
4. `ACTIONBAR_SLOT_CHANGED` fired with payload **`6`** (the slot) for each write.

There was **no `ADDON_ACTION_BLOCKED`/`FORBIDDEN`** during the run.

### Ranks
- `C_SpellBook.IsSpellBookItemLowRank` returns **true for lower ranks** and false for the top rank (checked on 3 spells).
- `C_Spell.GetBaseSpell`, `FindBaseSpellByID` and `C_Spell.GetOverrideSpell` return **the same ID for every rank**. They do **not** map one rank to another.
- `FindSpellBookSlotForSpell(id)` returns that rank's own book slot (25 and 26 for the two Raptor Strike ranks).
- **Consequence for #5:** the spell-family key is the spell **name** (`C_Spell.GetSpellName`). "Highest known rank" is the same-name spellbook entry that is *not* `IsSpellBookItemLowRank`. No API links ranks, so the profile stores the name.

### Macros
- `Constants.MacroConsts` = `{MAX_ACCOUNT_MACROS = 120, MAX_CHARACTER_MACROS = 30}`. The `MAX_*_MACROS` globals stay nil, so read the constants.
- `CreateMacro(name, icon, <255-char body>, true)` returned **125**. The body read back at 255 characters.
- **After a full exit, no character macro with that exact name and body was found.** It was either lost or changed (the follow-up `/run` in #25 decides which). For comparison, Stakeout measured character macros surviving a logout on 69977, with a shorter body.

### Bindings
- `GetCurrentBindingSet()` = **2 (Character)** on this character. `Enum.BindingSet = {Default = 0, Account = 1, Character = 2, Current = 3}`. `GetNumBindings()` = 333.
- `SetBinding("CTRL-SHIFT-F11", "TOGGLEAUTORUN")` followed by `SaveBindings(Enum.BindingSet.Character)` caused no taint and **survived a full exit**. Removing it the same way worked.
- Blizzard's own set switching, from `Blizzard_Settings.lua`:
  - Account → Character is `SaveBindings(Account); LoadBindings(Character); SaveBindings(Character)`.
  - Character → Account deletes the character set, after a confirmation.
  - AltStableSync never switches sets for the player.

### CVars
- `cameraDistanceMaxZoomFactor`: `GetCVarInfo` returned `"1", "1.000000", isStoredServerAccount = true, false, false, false, false`.
- `SetCVar` to 1.5 returned true and **survived a full exit**. The restore worked.
- That is one account-stored CVar. Character-stored CVars are not measured.

### Login order (ms after the probe's file loaded, fresh login)
| ms | event | readable at that point |
|---:|---|---|
| 9 | ADDON_LOADED (own) | nothing: macros 0/0, slot 1 nil, no keys, spellbook 0 |
| 2273 | UPDATE_BINDINGS | keys still nil; **readable from the 2nd fire** (2276) |
| 8096 | UPDATE_MACROS | **account macros only (3/0)**; character macros arrive on the 2nd fire (3/4) |
| 8182 | ACTIONBAR_SLOT_CHANGED (arg 0) | slots and spellbook (37 entries) readable |
| 8493 | EDIT_MODE_LAYOUTS_UPDATED | |
| 8642 | PLAYER_LOGIN | everything readable |
| 9068 | PLAYER_ENTERING_WORLD | |
| 10048 | SPELLS_CHANGED | fires *after* PLAYER_ENTERING_WORLD |

Event counts: UPDATE_BINDINGS ×5, UPDATE_MACROS ×6, ACTIONBAR_SLOT_CHANGED ×23, SPELLS_CHANGED ×2.

**Consequence for the readiness gate (#4):**
- The first UPDATE_MACROS is a trap: character macros are not there yet.
- In this sample everything read correctly by PLAYER_LOGIN.
- The gate waits for the first SPELLS_CHANGED after PLAYER_ENTERING_WORLD, then checks that the macro counts have not dropped.

### Edit Mode (codec only)
- `GetLayouts()` returned 2 saved layouts with `activeLayout = 4`, so two presets come first. `layouts[1]` = `"My UI"`, type 1, 59 systems.
- `ConvertLayoutInfoToString` produced 2724 characters, starting `"4 0 59 0 0 0 7 7"`.
- `ConvertStringToLayoutInfo` gave back **name `""` and type 0**, with all 59 systems. Re-encoding gave an identical string.
- **Consequence for #15:** the string carries the systems only. Store the layout name and type beside it. Blizzard's own import also asks for a new name.

### C_EncodingUtil
- Test payload: a worst-case profile with 180 slots, 18 macros of 255 characters and 150 bindings.
- Sizes: CBOR 22,335 bytes, then Deflate 2,023, then Base64 2,700. Encoding took 0.7 ms.
- The decode round trip is **deep-equal**, and integer keys survive as numbers.
- **Consequence for #17/#18:** the envelope is small. A whole profile fits well under LibAccountSync's 16 KB.

## Still open after the 70245 run

- Was the probe macro lost or changed after the exit? (follow-up `/run` in #25)
- How do we identify the macro in an action slot, including for a macro whose spell is not learned? (follow-up in #25)
- Does any taint appear after `/reload` following `place`?

## Originally to measure (#2)

Spec/talent APIs, `GetActionInfo` shapes, rank → family mapping, macro persistence across a full
restart, binding-set behaviour and persistence, login readiness event order, Edit Mode round-trip,
CVar persistence, `WOW_PROJECT_ID` / region for the flavour fingerprint. Results land below as
`## Build <version>.<build>` sections, each with the exact `/run` lines used, so a client update can
re-run them (see the client-update skill).
