# Forever API notes — AltStableSync

Facts **measured on the client** that this addon depends on. Declared shapes come from the dump
(`C:\Projects\References\forever-api-<version>.<build>.md`); addon-agnostic findings belong in the
canonical `C:\Projects\References\PORTING-TBC-TO-FOREVER.md`, not here.

`MEASURED_ON_BUILD` in `Core.lua` names the build this file describes: **70291**. The 70245 measurements below were
re-checked on 70291 (see its section).

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

These were measured with `Tools/AltStableSyncProbe` (`/syncprobe`, PR #25). The macro, CVar and binding markers were armed one after another. Then the **owner did one full client exit** (stated by the owner) before `/syncprobe restart`. Both load counters went up by exactly one, which is consistent with that but proves nothing on its own: `/reload` bumps them too.

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
  - All four macro slots behave this way, including `/Cast Concussive Shot` with no `#showtooltip`, which reports 5116.
  - **The cursor gives the real index.** `PickupAction(1)` then `GetCursorInfo()` returns `"macro", 122`, the true index. `PlaceAction(1)` puts it back, and it reads `"macro", 75, "spell"` again.
  - **Consequence for capture (#6):**
    - Identify a macro slot by `GetActionText(slot)`, which is the macro name and is always readable, whatever spell the macro shows or whether that spell is learned.
    - Match the name against the macro list.
    - When a name is duplicated, use the cursor round trip, out of combat, to read the true index.
    - Never use the action's id.
- **Design rule (reasoned from Blizzard behaviour, not measured here): macros never wait on a spell.** A macro is placed whether or not its spell is learned; it shows "?" until it is. So applying a profile does not defer a macro slot because a spell is unlearned. Only spell slots and item slots are deferred. #13's rehearsal checks this on a low-level alt.
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
- **Consequence for #5:** the spell-family key is the spell **name** (`C_Spell.GetSpellName`). "Highest known rank" is the same-name spellbook entry of item type `Enum.SpellBookItemType.Spell` (not a FutureSpell or Flyout) that is *not* `IsSpellBookItemLowRank`. The first run did not filter by item type. The ranks it listed were still learned: `FindSpellBookSlotForSpell`, which skips future spells by default, found every one. No API links ranks, so the profile stores the name.

### Macros
- `Constants.MacroConsts` = `{MAX_ACCOUNT_MACROS = 120, MAX_CHARACTER_MACROS = 30}`. The `MAX_*_MACROS` globals stay nil, so read the constants.
- `CreateMacro(name, icon, <255-char body>, true)` returned **125**. The body read back at 255 characters.
- **The macro survived the full exit, but its body changed from 255 to 256 characters.** Every body the client returns ends in a newline (`"/cast Arcane Shot\n/petattack\n"` is 29 characters), so the server **appends a trailing newline**. The probe's exact-body match missed it for that reason.
  - **Consequence for #6:** compare macro bodies with trailing newlines normalised. Capture stores the body as the client returns it. Exact restore compares normalised bodies, and the reuse rule (name + body + scope) uses the normalised body.
  - The 255-character limit is only kept in memory. Whether the server truncates a body that becomes 256 characters with the newline is untested; keep bodies at 254 characters or less.

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
- The gate waits for the first SPELLS_CHANGED after PLAYER_ENTERING_WORLD, then checks that the macro counts have not dropped. *(Superseded as an implementation rule by the readiness predicates in `docs/DESIGN.md`; the trace above stands as measured.)*

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
- **Measured with real loadouts on 70291 (#5, 2026-10-09):** the largest of 5 saved entries, covering every bar, encodes to **1,508 bytes** on the wire (envelope plus id and version).

## Build 1.60.1.70291 (2026-10-08) - client update, re-checked by hand

The client was built on Oct 7, 2026, interface 16001.

**Dump diff against 70245** (`Compare-Dumps.ps1`):
- **Voice Chat and Discord:**
  - `VoiceChatID` and `DiscordMemberOpaqueID` types;
  - a voice-provider API (`C_VoiceChat.Get/Set/RestoreActiveVoiceProvider`, `C_Discord.IsVoiceEnabled`) and its events.
- **LFG:** structures gained `voiceMode`.
- **New functions:** `GetGlancingBlowChance` and `GetGlancingBlowPenalty`.
- **Unchanged:**
  - every function and event this addon or LibAccountSync calls, including the action-bar, macro, binding, `C_EncodingUtil`, `C_EditMode`, `C_CVar` and Battle.net surfaces;
  - widget methods.

**Behaviour.** The owner ran these lines on a hunter, out of combat:

| `/run` line | 70291 | Same as 70245? |
|---|---|---|
| `print(GetBuildInfo())` | `1.60.1 70291 Oct  7 2026 16001` | build moved, as expected |
| `print(WOW_PROJECT_ID, GetCurrentRegion(), GetNumSpecGroups(), C_SpecializationInfo.GetActiveSpecGroup(), GetCurrentBindingSet())` | `18 110 1 1 2` | yes, except the **region: 90 → 110** |
| `for s=1,12 do local t,i,u=GetActionInfo(s) if t then print(s,t,i,u,GetActionText(s)) end end` | `spell <id> spell` for spells; `item <id>` for items | yes |
| `local s=1 print(GetActionInfo(s)) print(GetActionText(s)) PickupAction(s) print(GetCursorInfo()) PlaceAction(s)` (account macro `RXPTargeting`) | `macro 2`; `RXPTargeting`; `macro 2` | yes, plus the new case below |
| `local E=C_EncodingUtil local s=E.EncodeBase64(E.CompressString(E.SerializeCBOR({s=1,a="x"}))) local t=E.DeserializeCBOR(E.DecompressString(E.DecodeBase64(s))) print(#s,t.s,t.a)` | `16 1 x` | yes, round trip intact |

- **New case: a macro with no spell.** A macro that shows no spell reports `"macro", <its own macro index>` and **no** third value. It does not report a spell id. Account macro 2 read back as index 2 from both `GetActionInfo` and the cursor.
  - **Capture is unaffected:** it identifies macros by `GetActionText`, never by the id.
- **The region value moved between builds:** `GetCurrentRegion()` was 90 on 70245 and is 110 on 70291, on the same account. LibAccountSync reported region 110 in the same session, and linking worked.
  - Like the project ID, **the region is never a flavour key or a migration trigger.**
- The two-account Link rehearsal for PR #36 ran on this build the same evening. Battle.net messaging, the Link store file and the catalog file all worked.

**Verdict:** nothing this addon depends on changed. `MEASURED_ON_BUILD` is now 70291.

**Profession spells are outside the class skill lines** (owner, 2026-10-09, level-18 warlock; #46/#48):
Enchanting 7411, Tailoring 3909, Disenchant 13262, First Aid 3273, Cooking 2550 are **not** in the
`C_SpellBook` skill-line scan (`Game.Spellbook`), yet `C_SpellBook.IsSpellKnown(id)` and
`IsPlayerSpell(id)` both return `true`. So "not in the scan" is never proof of "not learned": absence
also needs both by-id answers to be `false`.

**Action bars after training a new rank** (owner, 2026-10-09, from play; #42):
- **Hunter** bars switch to the new rank by themselves.
- **Caster** bars keep the old rank, unless the spell is cast through a macro.
- So a low rank alone on a caster's bar is usually stale, not a choice. Healers, though, keep two or three ranks of one heal on purpose to save mana.
- Ranks are separate, ascending spellbook items (Raptor Strike ranks 1 and 2 at book slots 25 and 26, above), so book order gives rank order.

### Action bars: button → slot, per state (#5, 2026-10-09)

Measured with `/syncprobe bars` (`Tools/AltStableSyncProbe`) on four low-level characters: a hunter,
a warrior, a druid and a rogue. None of them had a second stance, a form or stealth yet.

**Buttons → slots** (every button reports its slot through `GetPagedID`; identical on all four):

| Bar (Settings name) | Frame | Slots |
|---|---|---|
| Action Bar 1, page 1 | `ActionButton1–12` | 1–12 |
| Action Bar 1, page 2 (paging) | `ActionButton1–12` | 13–24 (page 2 measured on the hunter) |
| Action Bar 4 | `MultiBarRightButton` | 25–36 |
| Action Bar 5 | `MultiBarLeftButton` | 37–48 |
| Action Bar 3 | `MultiBarBottomRightButton` | 49–60 |
| Action Bar 2 | `MultiBarBottomLeftButton` | 61–72 |
| Battle Stance (warrior) | `ActionButton1–12` | **73–84**; slot 1 keeps its own content underneath |
| Action Bars 6–8 | `MultiBar5/6/7Button` | 145–180 |

- `C_ActionBar.GetBonusBarIndexForSlot`: 73–84 = 7, 85–96 = 8, 97–108 = 9, 109–120 = 10,
  121–132 = 11; nothing else has one (1–200 scanned, on all four characters).
- `OverrideActionBarButton1–6` show slots 1–6: the override bar aliases Action Bar 1 and stores nothing.
  `BonusActionButton` doesn't exist. Bonus/override/vehicle/temp-shapeshift/extra bar indices: 0, 33,
  31, 32, 34 out of any form.
- **Hidden bars keep their slots.** On the warrior, druid and rogue, Action Bars 2–8 were hidden
  (0/12 visible); their buttons still map to the same slots.
- **Slots 181–200 hold copies** of main-bar actions on every character (e.g. 181–184 = slots 9–12's
  contents in another order, 197 and 200 = slots 3 and 2). No button ever shows them.
- **`/syncprobe bars write <slot>`** (an empty slot, out of combat, not in a form): written, read back,
  picked up and the slot and cursor empty again, with **no `ADDON_ACTION_BLOCKED`/`FORBIDDEN`**, on
  slots 80, 90, 100 and 115 (pages 7–10, none active), 20 (page 2 while page 1 shows) and 150 (a
  hidden Action Bar 6).
- **The page that's showing takes writes too.** The warrior in Battle Stance (`GetShapeshiftForm` 1,
  `GetBonusBarOffset` 1, so Action Bar 1 shows slots 73–84): `/syncprobe bars write 80` wrote, read back
  and emptied slot 80, with the cursor empty and no `ADDON_ACTION_BLOCKED`/`FORBIDDEN`.
- **Binding commands** (`GetNumBindings`/`GetBinding`, for #7): 116 — `ACTIONBUTTON1–12`,
  `MULTIACTIONBAR1–7BUTTON1–12`, `BONUSACTIONBUTTON1–10`, `SHAPESHIFTBUTTON1–10`. No `MULTIACTIONBAR8`.

**Consequence for #5:** a loadout covers slots **1–120 and 145–180**, by slot id. **121–132**
(page 11: skyriding/possess), **133–144** (no button showed them) and **181+** (shadow copies) are never
read or written. **Not measured yet:** which form or stance uses which of pages 7–10 (no character
had one); the preview names them "Stance/form page 1–4". A druid, warrior or rogue that gets its form
or stealth can confirm with `/syncprobe bars <label>` in that form.

## Still open

- Does any taint appear after `/reload` following `place`? (Nothing was reported during the run.)
- What a macro slot reports as its id when its spell is **unlearned**. (A macro with no spell is answered on 70291.) **Not needed:** capture uses `GetActionText`, never the id.

## Originally to measure (#2)

Spec/talent APIs, `GetActionInfo` shapes, rank → family mapping, macro persistence across a full
restart, binding-set behaviour and persistence, login readiness event order, Edit Mode round-trip,
CVar persistence, `WOW_PROJECT_ID` / region for the flavour fingerprint. Results land below as
`## Build <version>.<build>` sections, each with the exact `/run` lines used, so a client update can
re-run them (see the client-update skill).
