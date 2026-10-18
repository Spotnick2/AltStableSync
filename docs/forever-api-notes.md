# Forever API notes — AltStableSync

Facts **measured on the client** that this addon depends on. Declared shapes come from the dump
(`C:\Projects\WoW\References\Forever\api\forever-api-<version>.<build>.md`); addon-agnostic findings belong in the
canonical `C:\Projects\WoW\References\Docs\PORTING-TBC-TO-FOREVER.md`, not here.

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
  - AltStableSync switches only Account -> Character, on the player's OK (#7).
- Account -> Character, measured on 70291 (#7, a character on Account after a full exit; the full
  binding map compared after each call, an `UPDATE_BINDINGS` listener running):

  | After | `GetCurrentBindingSet()` | Keys as before |
  |---|---|---|
  | (before) | 1 | — |
  | `SaveBindings(1)` | 1 | yes |
  | `LoadBindings(2)` (fires `UPDATE_BINDINGS` inside the call) | **1** | yes |
  | `SaveBindings(2)` | 2 | yes |

  No `ADDON_ACTION_BLOCKED`/`FORBIDDEN`. The Settings checkbox shows ticked afterwards. After a full
  exit: set 2, the same 127 bound commands, the same fingerprint length. Running the same three
  calls while Character is active would save that character's keys as the Account set.
  Not measured: what `LoadBindings(Character)` does when an older Character store exists (Blizzard's
  untick deletes it), what a reload restores after a partial switch, and `LoadBindings(Account)`
  while Account is active (the stop path's reload; Blizzard's Keybindings Cancel does the same).
  `GetBinding(i)` lists only Bindings.xml commands: keys bound with `SetBindingClick` and the like
  are read with `GetBindingAction(key)` over every ALT/CTRL/SHIFT/META chord of the keyboard, mouse
  buttons 1-31 (Blizzard's `BindingUtil` range), the wheel and the gamepad.

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

## Build 1.60.1.70338 (2026-10-11) - client update, covered by in-game use

The client was built on Oct 9, 2026, interface 16001, `WOW_PROJECT_ID` 18.

**Dump diff against 70334** (`Compare-Dumps.ps1`): the documented surface is **identical**: 6604
functions, 1810 events, 798 tables, 7530 widget methods and 5421 namespace functions. Only the `_G`
walks changed (+35 -0 globals, +247 -66 namespace candidates), which is other addons' noise.

**Behaviour.** The `/run` lines of the 70334 section weren't re-run. The surface they cover was
used on 70338 instead (owner, 2026-10-10/11, both accounts): Load, Save and Save As of real
loadouts on hunters, including keys under Character bindings (#52: pet keys saved on one account,
loaded on the other); catalog sync between the two accounts; and the `/syncprobe pet` runs in the
"Pet bar (#47)" section (action and pet-bar cursor round trips, spellbook pickup).

**Verdict:** nothing this addon depends on changed. `MEASURED_ON_BUILD` is now 70338.

## Build 1.60.1.70334 (2026-10-10) - client update, re-checked by hand

The client was built on Oct 9, 2026, interface 16001.

**Dump diff against 70291** (`Compare-Dumps.ps1`): the documented surface is **identical**: 6604
functions, 1810 events, 798 tables, 7530 widget methods and 5421 namespace functions. Only the `_G`
walks changed (+1 -155 globals, +67 -328 namespace candidates), which is other addons' noise. Every
global this addon calls is still in the dump.

**Behaviour.** The owner ran these lines on a hunter, out of combat:

| `/run` line | 70334 | Same as 70291? |
|---|---|---|
| `print(GetBuildInfo())` | `1.60.1 70334 Oct  9 2026 16001` | build moved, as expected |
| `print(WOW_PROJECT_ID, GetCurrentRegion(), GetNumSpecGroups(), C_SpecializationInfo.GetActiveSpecGroup(), GetCurrentBindingSet())` | `18 110 1 1 2` | yes |
| `for s=1,12 do ... GetActionInfo(s) ... GetActionText(s) end` | `macro <spell id> spell <name>` for macros showing a spell; `spell <id> spell`; `item <id> nil` | yes |
| `local s=1 print(GetActionInfo(s)) print(GetActionText(s)) PickupAction(s) print(GetCursorInfo()) PlaceAction(s)` (character macro `AuS`) | `macro 75 spell`; `AuS`; `macro 122` | yes: the cursor gives the macro index (122, a character macro) |
| `local E=C_EncodingUtil ... print(#s,t.s,t.a)` | `16 1 x` | yes, round trip intact |

Also on this build (owner, 2026-10-10): #7's switch to character keybindings, the two-step wizard and
its full-exit check (PR #50).

**Verdict:** nothing this addon depends on changed. `MEASURED_ON_BUILD` is now 70334.

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

**Spellbook tabs and unlearned spells** (owner, 2026-10-09; #46/#48):
- Forever lists **no future (unlearned) spells**: item types on a level-18 warlock were Spell 31, Flyout 1,
  FutureSpell (2) none. So "not in the book" can't tell a class spell not learned yet from someone else's.
- Skill line 1 is **"General"**: Attack, Escape Artist, Eureka!, Shoot, Armor Proficiency, Dodge, Engineering
  Specialization, Expansive Mind, Languages (gnome warlock, book 1-9). Racials and shared spells live there.
  Lines 2-4 are the class trees (Demonology 10-18, Affliction 19-27, Destruction 28-32).
  `FindSpellBookSlotForSpell(20589)` (Escape Artist) = 2.
- When a character learns a spell, the client adds it to the **first empty action-bar slot** (owner, from play).

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

### Pet bar (#47, 2026-10-10, build 70338)

Measured with `/syncprobe pet` (`Tools/AltStableSyncProbe`), out of combat, on two hunters with a bear
each (one per account) and two warlocks with an imp each. No other family or demon was available.
**Not measured:** other demons (Voidwalker, Succubus/Incubus, Felhunter), other hunter families, and a
stable swap between two pets of one hunter.

| Question | Measured |
|---|---|
| Pet type | `UnitCreatureFamily("pet")` → `"Bear", 4` and `"Imp", 23` on every character. The name is localised; **the id is the key**. |
| Pet identity | `UnitGUID("pet")` changes on every summon and every login (`Pet-0-4615-1-548-…-0100334699` → `…-0200334699` → `Pet-0-4621-1-50543-…`): **never a key**. |
| A slot | `GetPetActionInfo(i)`, i = 1–10 → name, texture, isToken, isActive, autoCastAllowed, autoCastEnabled, spellID, checksRange, inRange. An empty slot returns nothing or `nil` with `false` flags. |
| Commands and stances | isToken = 1 and a fixed name: `PET_ACTION_ATTACK`, `PET_ACTION_FOLLOW`, `PET_ACTION_MOVE_TO`, `PET_MODE_ASSIST`, `PET_MODE_DEFENSIVEASSIST`, `PET_MODE_PASSIVE` (the default layout: 1–3 and 8–10, on all four). Aggressive, Attack, Stay and the others are pet spellbook entries with no spell id. |
| Abilities | Localised name plus spell id; **each rank has its own id** and `FindBaseSpellByID` returns the id itself (Growl rank 1 2649 / rank 2 14916; Firebolt rank 1 3110 / rank 3 7800). |
| Pets of one family differ | Bear: Growl + Claw + Bite vs Growl only. Imp level 18: Firebolt, Blood Pact, Phase Shift, Fire Shield vs level 4: Firebolt only. |
| Pet spellbook | `C_SpellBook.HasPetSpells()` → count, `"PET"`; entries through `GetSpellBookItemInfo(i, Enum.SpellBookSpellBank.Pet)` (bank 1), sorted by name, passives included (Great Stamina, Natural Armor). |
| Move by code | `PickupPetAction(a)`, `PickupPetAction(b)`, `PickupPetAction(a)` swaps two slots; the cursor reports `"petaction", <spell id>` (`2` for a stance); swapped back exactly, cursor empty, **no `ADDON_ACTION_BLOCKED`/`FORBIDDEN`** (bear and imp). |
| Place from the book | `C_SpellBook.PickupSpellBookItem(i, Pet)` then `PickupPetAction(empty slot)`: placed (a stance, Aggressive), taken off again with `PickupPetAction` + `ClearCursor`, nothing blocked. |
| Move into an empty slot (2026-10-11) | `PickupPetAction(j)`, `PickupPetAction(empty i)` moves a command (Attack, slot 1 → 7): source empty, cursor empty; moved back the same way; picking a slot up and dropping it on the same slot puts it back. The cursor reports `"petaction", 2` for a command as for a stance, so the cursor can't tell what it holds. Nothing blocked. |
| Remove and re-place from the book (2026-10-11) | Growl (14916) taken off with `PickupPetAction` + `ClearCursor`, then `C_SpellBook.PickupSpellBookItem(book, Pet)` + `PickupPetAction(slot)`: back in its slot, and **its autocast survived both ways** (on → on, off → off, 1 s later too; the spellbook keeps the state while it is off the bar). Nothing blocked. |
| Autocast | **Protected.** `TogglePetAutocast(slot)` and `C_SpellBook.SetSpellBookItemAutoCastEnabled` both raise `ADDON_ACTION_FORBIDDEN`; the state doesn't change. |
| Keys | `BONUSACTIONBUTTON1–10` (here CTRL-1 … CTRL-0); `PetActionButton1–10` show pet slots 1–10. |
| Persistence | The game keeps **each pet's own bar**: a hand-arranged bar came back unchanged after a dismiss and resummon, and after a full client exit (bear and imp). |

**Consequence for #47:** the game already remembers a pet's bar on the character that owns it. What a
loadout adds is the cross-character copy, keyed by family id; abilities match by spell across ranks,
commands and stances by name; autocast stays as it is and the preview says so. Moves into empty slots
and remove/re-place from the book both work and keep autocast, so a load can rearrange, empty and fill
pet slots (measured on one bear; the ability move was measured as a swap only).

### EditMacro (#6, 2026-10-12, build 70338)

Measured with `/syncprobe macro`, `/syncprobe macroedit` and `/syncprobe macroedit combat`
(`Tools/AltStableSyncProbe`) on one character's own test macro, placed in an empty bar slot first.
Then a **full client exit**, `/syncprobe restart` (it reported "a login", not a `/reload`), and
`/syncprobe clean`.

| Question | Measured |
|---|---|
| The call | `EditMacro(122, name, 134414, body)` returns **122**, the same index. `GetNumMacros()` is unchanged (3 account, 2 character). No taint. |
| Read back | `GetMacroInfo(122)` → the same name, the new body, and icon **134414 as a number**. The icon before was also a number (134400, made from `"INV_Misc_QuestionMark"`), so a fileID goes in and comes out unchanged. |
| A bar slot holding it | Still `"macro", 122` with the macro's name, after the edit and after the full exit. Every button on the macro shows the new text. |
| In combat | **Protected.** `ADDON_ACTION_BLOCKED … UNKNOWN()`, no return, and the macro is unchanged. |
| Full exit | The edited body and icon survived, at index 122, and so did the slot. |
| Trailing newline | The body read 83 characters right after the edit and 84 after the next load, a `/reload` as well as the full exit. So the server's trailing newline comes back on a `/reload` too; on 70245 it was only seen after a full exit. |
| `DeleteMacro(122)` | No return; **the slot holding it becomes empty**. |

**Consequence for #6:** an update is one `EditMacro` call on the macro's own index. Read it back by
name, with bodies compared without trailing newlines, and the icon compared as a number. The load
never calls it in combat (the write guard refuses first, and a refused or silently dropped edit fails
the read-back as "macro not updated"). Deleting a macro empties its slots, which is one more reason a
load or a restore never deletes one.

### Edit Mode layouts: the write side (#29, #58, 2026-10-12, build 70338)

Measured with `/syncprobe layouts`, `layoutadd`, `layoutupdate`, `layoutactivate`, `layoutclean`
and `bartoggle` on one beta account (Kaleid), with a relog between rounds and a check on a second
character (Drakuzo). The probe passes `SaveLayouts` the same shape as Blizzard's
`EditModeManagerFrame:SaveLayouts`: a copy of the presets, then the saved layouts.

| Question | Measured |
|---|---|
| Presets | **3** (Modern, Classic, Gamepad), so saved layouts start at index 4. The limit is 5 per type (`EditModeMaxLayoutsPerType`). |
| Add an Account layout | `SaveLayouts(presets + saved + new)` then `OnLayoutAdded(6, false, true)`: the copy of "My UI" read back with identical content, the other layouts were byte-identical, the active layout stayed "My UI", no taint. |
| Blizzard's copy after an add | **Refreshed.** The client sent `EDIT_MODE_LAYOUTS_UPDATED` (`reconcile=true`), and `EditModeManagerFrame.layoutInfo` matched by name and content. |
| Replace a layout in place | `SaveLayouts` alone wrote the new content and left the others byte-identical, but **sent no event**: Blizzard's copy kept the OLD content. A later Save in Edit Mode would write it back over ours. |
| The fix for that | `SetActiveLayout(<the current active index>)` right after: the client sent `EDIT_MODE_LAYOUTS_UPDATED` (`reconcile=false`), Blizzard's copy matched again, the active layout was unchanged, no taint. |
| Persistence | After a **full client exit** (round 2), the replaced content was there as written, on Kaleid and on Drakuzo. |
| `SetActiveLayout` | To the new layout and back, found again **by name**: each switch sent the event, Blizzard's copy followed, no taint. |
| Remove | `SaveLayouts(without it)` then `OnLayoutDeleted(6)`: gone, the others byte-identical to the backup taken before the add, the active layout unchanged, event sent, no taint. |
| `SetActionBarToggles` | Bar 8 off: read back immediately (no server delay seen), on again: verified, no taint. Bars 2-8 are seven booleans. |
| Damage meter | `damageMeterEnabled` = "1" (a CVar). The `ShowDamageMeter` Edit Mode account setting is Edit Mode's own display toggle. A window's segment (`sessionType`, Overall = 0, Current = 1) lives in Blizzard's per-character SavedVariables `DamageMeterPerCharacterSettings`, which an addon must not write. |

**Consequences:**
- #58 is feasible: every write is `SaveLayouts` with the full list, then `OnLayoutAdded`,
  `OnLayoutDeleted` or (for a replace) `SetActiveLayout(active)`, then a read-back by name and content
  **including Blizzard's copy**. Never with Edit Mode open, never in combat.
- Content equality is string equality of `ConvertLayoutInfoToString` (stable, 70245), so "this layout
  differs from the other account's" is a string compare.
- **Another character's active layout is a raw index.** Drakuzo had a Character layout, CharTest, active
  at index 6. Kaleid added an Account layout, which went in at index 6 and pushed CharTest to 7. At its
  next login Drakuzo was on **SyncProbe**. After the removal it was back on CharTest. `OnLayoutAdded`
  only corrects the character that makes the call. Adding or removing an Account layout therefore moves
  every other character whose active layout comes after that position, which means every Character
  layout user. Replacing in place moves nobody. Blizzard's own `MakeNewLayout` inserts the same way, so
  creating an Account layout in Edit Mode probably does this too (not measured).
- One unexplained switch: in the first round, Kaleid's active layout became SyncProbe within 22 s of
  the add, with Edit Mode opened in between. The owner isn't sure whether they clicked it. Two later adds
  stayed inactive throughout.
- The damage meter's segment stays manual.

### Pipes in text (#75, 2026-10-13, build 70338)

Measured by hand with `/run` lines from the chat box.
- **A `|` typed into an EditBox is stored as `||`.** `GetText()` returned 4 bytes for a typed `a|b`.
- **The chat box does the same** to a typed `/run` line, so every `|` in it reaches Lua as `||`. Spell a pipe `\124` in a `/run` test.
- **A FontString draws `||` as one `|`.** Strings with 2, 4, 6 and 8 pipes in a row drew 1, 2, 3 and 4, and the colour code after 6 or 8 pipes didn't render.
- **So stored text is WoW text.** A name typed in our boxes holds `||` for each pipe the player sees, and a single `|` can only come from an import, a sync or a SetText. Display neutralises odd runs (`ASS.Literal`), and macro code doubles every pipe (`ASS.Code`).
- **An EditBox draws SetText's text like a FontString.** One pipe before a colour code drew red, two drew one plain pipe, four drew two. So the typed form (`Literal`) shows literally in a box too, as the Import name box did with a crafted name, holding `||cff…`.
- **`SetMaxLetters` counts `||` as one letter** and keeps it escaped. A 12-letter limit kept `B||cffff0000y`, 13 bytes.
- **One unexplained screenshot:** the first time, the Import name box drew a crafted name in red. Three later runs, after a `/reload`, with focus moved between the boxes, drew it plain and held the escaped text. It wasn't reproduced.

## Still open

- Does any taint appear after `/reload` following `place`? (Nothing was reported during the run.)
- What a macro slot reports as its id when its spell is **unlearned**. (A macro with no spell is answered on 70291.) **Not needed:** capture uses `GetActionText`, never the id.

## Originally to measure (#2)

Spec/talent APIs, `GetActionInfo` shapes, rank → family mapping, macro persistence across a full
restart, binding-set behaviour and persistence, login readiness event order, Edit Mode round-trip,
CVar persistence, `WOW_PROJECT_ID` / region for the flavour fingerprint. Results land below as
`## Build <version>.<build>` sections, each with the exact `/run` lines used, so a client update can
re-run them (see the client-update skill).
