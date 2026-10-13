# AltStableSync — design

> The design of record. It describes the **manual presets** product the owner chose on 2026-10-08,
> which replaced the continuous-sync design of 2026-10-06. The pivot handoff is
> summarised here; the acceptance cases are in `docs/ACCEPTANCE.md`, and the storyboard and
> clickable mockup are in `docs/storyboard/` and `docs/mockups/`. Issue numbers are GitHub issues.
> Change this file when a decision changes. `AGENTS.md` points here.

## The product

**Choose a saved setup, preview it, and load it. Save only when you want to.**

AltStableSync is a WoW: Forever addon (interface 16001, Lua 5.1, Vanilla content on the Mainline
client). It keeps an **account-wide catalog** of two kinds of saved entry:

| | UI setup | Specialization loadout |
|---|---|---|
| Example | My UI; My UI - Druid | Priest / Discipline / Everyday |
| Purpose | Initialise how the interface looks, plus supported preferences | Reuse the controls for a chosen build |
| Contains | Edit Mode layout (#15) and a small allowlist of measured UI settings (#16). Supported addon appearance later (#22, #23). | Action bars, keybindings, and the character macros the bars need |
| Main action | Apply | Load |
| Update | Save | Save |
| Independent copy | Save As | Save As |
| Shared | Every character on the WoW account, and the owner's other WoW account (#18) | Same |
| Changes other characters when saved | **No** | **No** |

- **Load/Apply** reviews the planned changes, backs up this character, applies, verifies, and
  reports what was skipped.
- **Save** replaces the *selected* catalog entry with this character's observable configuration. It
  keeps inherited content this character can't represent (#28). Other characters keep their current
  state until they choose to load.
- **Save As** creates a separate entry with its own identity. The original is unchanged.
- **Local play never writes anything shared.** Moving buttons, editing macros, rebinding keys,
  levelling, logging in or shifting forms do not save or load anything.
- The highest-level character is a good *starting point*, not an authority. There is no master
  character.

The day-one goal is the **Forever launch on 2026-11-04**: profiles built on the beta are carried to
live by copying a file, then each live character loads what it wants. Myslot v6.2.0 was the
inspiration. Its model is not reused: paste strings, protobuf+CRC, StaticPopups, exact spell IDs with
no rank handling, clear-before-import, and a load path that skips its backup.

Owner decisions: the repo is **private until launch**; the addon is **personal use for now** (the
layout stays packager-ready); **never merge a PR without the owner's approval**.

### Non-goals (do not build)

Automatic sync of game state, master-character election, inheritance layers, publish/subscribe,
per-slot permanent override managers, automatic talent switching, generic conflict-merge UI,
arbitrary SavedVariables copying, a rules engine, a sync bus, a migration framework, a
version-history product, renaming the addon, hooking several Blizzard screens for the MVP, edits to
sibling repos, and Lua parsing in PowerShell.

## Facts established by research (treat as given)

Measured on the live client unless marked otherwise. Details and sources:
`docs/forever-api-notes.md` (this addon) and `C:\Projects\WoW\References\PORTING-TBC-TO-FOREVER.md`
(shared).

- **One spec per class, no dual spec** (70245). So a loadout's specialization is a **category the
  player picks**, not a native spec ID. Choosing it never changes talents.
- **Ranks are separate spell IDs, and no API links them.** `GetBaseSpell`, `FindBaseSpellByID` and
  `GetOverrideSpell` return the same ID for every rank. The spell family is the spell **name**. The
  highest known rank is the same-name spellbook entry of type `Enum.SpellBookItemType.Spell` that is
  not `IsSpellBookItemLowRank`. A low rank placed explicitly stays that rank.
- **A macro action slot reports the spell the macro shows**, not the macro index. The macro is
  identified by `GetActionText(slot)` (its name), or by picking the slot up and reading
  `GetCursorInfo()`.
- **The server appends a trailing newline to macro bodies.** Compare normalised; author at most 254
  characters. `Constants.MacroConsts` = 120 account / 30 character; character macros start at 121.
- **Bindings:** `SaveBindings(Enum.BindingSet.Character)` persists across a full exit. Blizzard
  switches sets with `SaveBindings(Account); LoadBindings(Character); SaveBindings(Character)`, and
  switching back deletes the character set. The addon switches only Account -> Character, on the
  player's OK (#7, rule 8); measured on 70291: the active set reads Account until the final save, the
  keys stay identical, `UPDATE_BINDINGS` fires inside `LoadBindings`, and it survives a full exit.
- **Readiness:** the first `UPDATE_MACROS` holds account macros only. Everything read correctly by
  `PLAYER_LOGIN`; `SPELLS_CHANGED` fires after `PLAYER_ENTERING_WORLD`.
- **Edit Mode:** the layout string round-trips the systems but **drops name and type**. Creating,
  activating, persisting and restoring a layout is **not yet measured** (#29).
- **`C_EncodingUtil`** CBOR→Deflate→Base64 round-trips. A worst-case loadout is 2.7 KB.
- **`WOW_PROJECT_ID` changed 1→18 between beta builds**: never a flavour or migration trigger.
- **LibAccountSync** reaches the owner's other WoW accounts on the same Battle.net account (same game
  and region only, by design). There is no delivery ack, and the cap is 32 KB (16 KB recommended).
  Its store holds a household key that must never be copied across flavours or exported.
- **Characters on one WoW account share account-wide SavedVariables** without any network.
- **Beta WTF layout** (measured on disk): `_classic_beta_\WTF\Account\<id>\SavedVariables\`; realm
  folder `70\`; character folders `Name-Surname\`. Blizzard's server-side binding, macro and Edit
  Mode caches are per flavour. The live Forever folder name is **unknown**, so tools take explicit
  paths.
- **Hard rules inherited from siblings:**
  - Never a StaticPopup; it taints Blizzard's dialog pool.
  - No protected work in combat.
  - `ReloadUI()` is protected.
  - Read SavedVariables at ADDON_LOADED, never at file scope.
  - Verify persistence with a full exit.
  - Guard secret values.
  - Characters have surnames.
  - **Never reassign a Blizzard global** (measured: `SlashCmdList = SlashCmdList or {}` tainted a
    secure `/tm` macro).

## Architecture

### Standalone addon, with AltStable as a later entry point

AltStableSync is its own addon in its own repo, fully functional without AltStable
(`## OptionalDeps: AltStable`). Later (#19), when AltStable is loaded, an AltStable sidebar tab opens
**the same panel**. There is no second state model. AltStable's `RegisterPlugin` is undocumented, so
#20 (AltStable-side, filed only with the owner's OK) would formalise it.

### Two different operations

- **Load/Apply is adaptive.** It resolves the highest known rank within a verified spell family
  (unless the entry deliberately holds a lower rank). Inside the entry's cover it makes each slot
  match the entry, emptying a slot whose entry this character verifiably can't use, and reports
  each one (#46).
- **Snapshot restore is exact.** It uses the captured IDs, literal macro content and binding values,
  never loadout resolution. A backup is a snapshot, never a catalog entry. Restore takes its own
  backup first.

### Pieces (responsibilities, not packages)

1. **Catalog** (#27): list, select, create, replace, delete; validate kind, class, category and schema;
   stable ids; version guard.
2. **Capture**: read only once ready; classify what is observable, unavailable or deliberately
   cleared.
3. **Plan**: resolve the selected entry against this character, the chosen modules and the binding
   destination. Emit changes, skips, conflicts and dependency order.
4. **Apply**: check the plan is still valid, take a verified backup, execute out of combat, verify
   each write, keep the result.
5. **Restore**: an exact plan from this character's snapshot, through the same
   backup/write/verify discipline.
6. **UI** (#9): one LibGlass panel, with simple views over these.
7. **Link** (#18): a separate small addon, `AltStableSyncLink`, that carries catalog entries between
   the owner's WoW accounts.

Use plain tables and file-local aliases in the repo's existing style. No rules engine, no generic sync
bus.

## Data model

```lua
AltStableSyncDB = {                 -- account-wide, file AltStableSync.lua
  schema = 8,                       -- #27 1 -> 2, #28 2 -> 3, #5 3 -> 4, #46 4 -> 5, #7 5 -> 6, #47 6 -> 7, #6 7 -> 8; an unknown or newer schema is refused untouched
  presets = {
    [id] = {
      id = "loadout-a1b2c3d4e5f6-12",          -- kind-writer-seq: never collides across accounts or copies
      kind = "ui" | "loadout",
      class = "PRIEST",                        -- loadouts only
      category = "discipline",                 -- loadouts only; a stable key, not a Blizzard spec ID
      name = "Everyday",                       -- a label, never identity
      version = "a1b2c3d4e5f6:17",             -- writer:seq of the Save that produced it
      parent = "f00dbabe0000:9",               -- the version it replaced (nil for a new entry)
      ancestors = { "f00dbabe0000:9", ... },   -- the last 20 versions this one descends from (incl. parent)
      created = <time>, updated = <time>,      -- display metadata only, never ordering
      provenance = { sourceChar = "Name-Realm", build = "70245" },
      modules = { actions = {...}, bindings = {...}, macros = {...},    -- loadout
                  cover = { {1, 120}, {145, 180} } }  -- the action slots captured (#5); 1-12 for older entries
                  -- a spell action from a class spellbook tab carries class = true (#46, schema 5)
                  -- pet = { [familyId] = { family, locale, slots = { [1..10] = { kind = "token", token }
                  --         | { kind = "spell", id, name } | false } } }: a pet bar per pet family (#47, schema 7)
             or { editmode = {...}, cvars = {...} },                    -- UI setup
      previous = { of = version, modules, updated },  -- LOCAL "undo my last Save": the content before the Save
                                               -- that produced version `of`; never sent, untouched by sync
      deleted = true,                          -- a versioned tombstone: no modules, kept indefinitely
      conflict = { of = "<id>", from = "Other-Char" },   -- a divergent copy kept whole
    },
  },
  backups = { [guid] = {                       -- exact runtime snapshots; each snapshot carries
                                               -- createdMacros = { {index, name, body}, ... }: the
                                               -- character macros the operation it preceded created
      ring = { <up to 10, oldest evicted> },  -- a snapshot of a pet bar write also holds
                                               -- pet = { family, familyName, guid, name, slots } (#47);
                                               -- one that updates character macros holds
                                               -- editedMacros = { {name, before = {body, icon},
                                               --   after = {body, icon}}, ... } (#6), written
                                               -- before the snapshot is stored
      firstSeen = <snapshot>,                  -- pinned forever
      operation = <snapshot> | nil,            -- the interrupted operation's original backup;
  } },                                         -- pinned until it completes or is abandoned
  origin = { build, region, project },         -- provenance only; never a migration trigger
}

AltStableSyncChar = {               -- per character
  schema = 8,                       -- same number as the DB; an unknown or newer one is refused untouched
  lastSelected = { ui = id, loadout = { category = "discipline", id = id } },
  loaded = {                        -- ONE baseline per kind: the last Load/Apply, or a Save/Save As (#28)
    ui = { id, version, baseline = <modules as loaded>, result = {...} },
    loadout = { id, version, baseline = <modules as loaded or saved>,
                after = <a capture right after a COMPLETED load, or as of the last Save> | nil,
                        -- after.bindings only when taken under Character bindings
                        -- after.pet = { [familyId] = { family, locale, slots, unavailable = { [slot] = reason } } }:
                        -- the pet out at that Load only (#47); none when its pet part couldn't be planned
                unavailable = { [slot] = reason },   -- baseline entries this character couldn't use
                result = { changed, created, keys, skips = { {slot, reason} }, failed, at } | { noop, skips } },
  },
  bindingsUnsaved = true | nil,     -- keys set in memory, not yet saved: the next Load/Restore saves
                                    -- even when every key matches (cleared by a successful SaveBindings)
  bindingSwitch = { before = { [command] = { key, ... } }, at, when } | nil,
                                    -- #7: a switch to character keybindings that stopped (schema 6)
  onboarding = { handled = true },  -- set by Not now, by opening the offer's preview, or by applying
  interrupted = { id, version, why, at },          -- resuming = a NEW preview + click;
                                                    -- its backup is backups[guid].operation
}

AltStableSyncLAS = <LibAccountSync store only>   -- declared ONLY by AltStableSyncLink.toc (below)
```

- **No stored writer id.** A writer token is a fresh random 12-hex string generated on every
  successful init and held in memory, with `seq` counting within the session. A stored id would be
  copied along with the file to both live accounts and reopen version collisions.
- **Schema 1 → 2** (#27): validate everything first. A schema-1 DB whose `profiles` is a table with
  `next(profiles) == nil` is stamped 2 and `profiles` is dropped, keeping `backups`. A populated or
  malformed schema 1 is refused untouched; the addon never wrote a profile, so none should exist.
  There is no migration framework. A missing or empty `AltStableSyncChar` is initialised at
  schema 2; a populated table without a schema, or one with an unknown or newer schema, is refused
  untouched, together with its DB. (Measured on disk: the scaffold build only ever wrote
  `AltStableSyncChar = {}`.)
- **Schema 2 → 3** (#28) only re-stamps both tables. A schema-2 `loaded` record keeps its shape and
  is never given an invented `after`: Save treats it as "no usable comparison". A mixed DB 3 /
  character 2 upgrades the character; a newer schema in either table refuses both untouched, so an
  older build can never Save As from a record whose meaning it doesn't know.
- **Schema 3 → 4** (#5): every loadout's `modules`, its `previous.modules` and each character's
  `loaded.loadout.baseline`/`after` get `cover = { {1, 12} }`: what the 1-12 builds captured. A slot
  outside an entry's cover was never captured, which is not the same as captured empty. A cover is
  never guessed: an entry arriving by sync without a valid one is rejected; locally, Create, Replace,
  Undo and Resolve refuse content without one ("bad-modules"), Load refuses an entry without one, and
  Save refuses a loaded record whose baseline or comparison lacks one ("load it again"); Save As then
  warns before a plain capture. A valid cover is ascending and canonical: adjacent ranges are merged,
  so one slot set has one spelling. Slots outside this build's set are listed by Load and Restore
  ("not supported on this build"), never written, and don't keep a backup "partial".
- **Schema 7 → 8** (#6) only stamps the number: 8 adds a backup's optional `editedMacros`. Catalog
  entries don't change, so the wire schema stays 4.
- **Schema 6 → 7** (#47) only stamps the number: 7 adds the optional `modules.pet`, a backup's `pet`
  and the record's `after.pet`. The wire schema moves 3 → 4 with it, so a schema-6 build never
  receives an entry with a pet bar by sync.
- **The pet bar** (#47, `Pet.lua`). A Load changes only the bar of the pet that is out, from its
  family's layout; nothing happens on summon. Abilities match by id, else by name in the same game
  language (another rank of the same ability); one the pet doesn't have empties its slot and is
  recorded as unavailable. Commands and stances are moved, never removed, since an addon can't put
  one back; autocast is never set (protected, and kept by the game across a re-place). The planner
  freezes every slot it can't reach and simulates the ten slots: moves and swaps, then removals of
  abilities the pet's book has, then placements from the book into empty slots. The executor
  guards every call (combat, the same pet GUID), reads each op back, and on a failure drops the
  payload back into the slot its op emptied or leaves it on the cursor and names the slot; it never
  clears a pet payload except in a planned removal. Restore needs the backup's pet (family and name)
  out. Save: the family not out keeps the entry's layout; the family out is merged slot by slot like
  the main bars (a slot the Load couldn't fill keeps the entry's; a new rank of the same ability is
  no change); an entry without it gets it added; no comparison, another game language or an
  unreadable bar keeps the entry's, with a note.
- **Coverage moves with the values.** Save outside the comparison's cover keeps B and says how many
  such slots differ ("load it again to save them"); outside the entry's cover it takes a readable C,
  so the first Save over a 1-12 entry adds the other bars, and an unreadable slot never gains cover.
- **Categories** (`Categories.lua`): per class, a short list of stable keys with display text, plus
  `general` ("General / Leveling").

  | Class | Categories |
  |---|---|
  | WARRIOR | arms, fury, protection |
  | PALADIN | holy, protection, retribution |
  | HUNTER | beast_mastery, marksmanship, survival |
  | ROGUE | assassination, combat, subtlety |
  | PRIEST | discipline, holy, shadow |
  | SHAMAN | elemental, enhancement, restoration |
  | MAGE | arcane, fire, frost |
  | WARLOCK | affliction, demonology, destruction |
  | DRUID | balance, feral_tank, feral_dps, restoration |

  Custom labels come later, only if needed.
- **Names:** a local Save As rejects a blank name, a whitespace-only name, and a duplicate within the
  same class/category list. The same name in another category is allowed. Names arriving by sync are
  never rejected. Names are always rendered as text.

## Trigger / write matrix

Only an explicit confirmation click writes game state.

| Trigger | May write the catalog? | May write game state (bars, macros, bindings, layout, CVars)? |
|---|---|---|
| Login, `/reload` | no (except the one-time schema upgrade) | **no** |
| Any game event (spells learned, forms, bags, combat end, readiness) | no | **no**. Availability may refresh, nothing more |
| Choosing an entry in a dropdown | no | **no** |
| First-login offer (#10) | no | **no**. It only opens a preview |
| Confirmation click on a Load/Apply/Restore preview | no | **yes**, after a verified backup |
| OK on the "Turn on character keybindings?" preview (#7) | no | **only** the binding-set switch, verified, guarded (safety rule 8) |
| Interruption (combat starts mid-apply) | no | stops writing. Resuming = a new preview + a new click |
| Save / Save As / Delete / Recover / Keep-this-version (confirmed) | **yes** | no |
| Catalog sync receipt (#18) | **yes**, by the receive rules | **no**, ever |
| Beta → live transfer script (#12) | copies the file, client closed | **no** |

## Safety model (non-negotiable)

1. **Backup before every apply, every resume and every restore.** If capturing the backup fails,
   nothing is written. A no-op plan needs no backup. While an operation is `interrupted`, its
   original backup sits in the separate `operation` slot (never evicted), so resumes can't push out
   the real before-state; each resume still takes its own ring backup, which keeps any edits the
   player made in between. There is at most one interrupted operation per character: starting a new
   Load/Apply/Restore shows "Abandon the interrupted Load of X?" in its preview, and abandoning
   moves that backup into the ring. The ring holds 10, plus the pinned `firstSeen`.
2. **Preview before write**, in our own frame. The preview captures an **immutable copy of the entry
   and its version**. Confirming applies exactly that copy, or refuses as stale if the entry, or the
   target state the plan relied on, changed since (A38).
3. **No clear-before-import.** Nothing is cleared up front; each slot is written or emptied on its
   own, after the backup, and read back.
   - **Inside the entry's cover, a Load makes the slot match the entry (#46, owner 2026-10-09).** An
     empty slot in the entry is "captured empty", so the destination is emptied. An entry this
     character **verifiably** can't use empties the destination too, and stays in the saved entry.
     The verified reasons: not learned, rank not known (absent from a complete spellbook read **and**
     unknown to the client by id, since profession spells may sit outside the class skill lines,
     **and** marked `class = true`: Forever lists no unlearned spells, so only a spell captured from
     a class tab, not "General" with its racials, nor a profession, is one this character can still
     learn; an unmarked one, including any saved before schema 5, is "not marked as a class spell"
     and left alone),
     not in bags, account macro missing (no macro of that name at all), macro name conflict, macro
     slots full. Each emptied slot is listed in the preview with its reason;
     one that is already empty is listed as "stays empty until this character can use it".
   - **Left untouched:** a slot outside the entry's cover (never captured) or outside the supported
     set; content the backup can't put back (a mount, a companion, an ambiguous macro); and any
     slot whose answer rests on a failed read (spellbook, bag count or macro list unreadable) or on
     the entry itself (a missing macro definition, a body too long, an unsupported kind, a spell
     with no name). An account macro of that name with another body is the player's own: left alone.
     A slot the entry has empty that holds content the backup can't restore is not listed at all.
   - The player loads or retries **explicitly**; nothing retries on an event.
   - **Cursor hygiene:** refuse to start unless the cursor is empty (so the player's own payload is
     never touched). Before each `PlaceAction`, the cursor must hold exactly what we picked up.
     After it, the cursor may hold the slot's **displaced previous action**; that action is already
     in the backup, so it is verified to be exactly the displaced one and then cleared. Anything
     else on the cursor stops the operation.
4. **Out of combat only.** Combat stops the operation and keeps an `interrupted` record. Readiness
   and combat-end events **never start or resume** anything; resuming is a new preview and a new
   click.
5. **Readiness gate (predicates, not one event):** capture and plan wait until
   `PLAYER_ENTERING_WORLD` has fired, the spellbook reports entries, and no `UPDATE_MACROS` or
   `UPDATE_BINDINGS` has fired for 2 seconds. The first `UPDATE_MACROS` (account macros only) and
   the first `UPDATE_BINDINGS` (keys still nil) are traps (measured on a fresh login, 70245). The
   order after `/reload` is re-measured in #29 before #4 relies on it.
6. **Validation:** check the schema, module versions, class, readiness and combat state before
   planning. Unknown or newer schemas are refused, at startup (both `AltStableSyncDB` and
   `AltStableSyncChar`) and in received envelopes.
7. **Ranks:** keep the original ID plus name. Adaptive load uses the highest known rank in the
   same-name family where the entry says "highest known". A deliberate low rank stays exact. Exact
   restore never upgrades. Ambiguous or cross-locale mappings are deferred, never guessed.
8. **Bindings are written to the Character set only, and only when it is the active set.** The
   preview shows "Destination: Character".
   - If the character uses Account bindings, the binding part is blocked with "Enable
     character-specific keybindings in WoW settings, then try again." When the set reads as Account,
     the preview offers **OK / Cancel** instead (#7). OK runs Blizzard's checkbox sequence,
     `SaveBindings(Account); LoadBindings(Character); SaveBindings(Character)`, and nothing else. It is
     step 1 of a two-step wizard: step 2 waits (display only, up to 10 s) for the switch's own
     `UPDATE_BINDINGS` to settle, then shows the ordinary Load preview, planned afresh, whose Load
     click is the only load write. Step 2 ends without loading if its preview is cancelled or
     replaced, the entry is gone, or the character is back on Account keybindings; cancelling it
     leaves character keybindings on.
     - The first call saves the keys in memory as the Account set, including changes another addon
       hasn't saved; the preview says so. On a Character set it would overwrite the account keys
       with this character's, so every call requires the set to read Account (it does until the
       last call, measured) and no combat.
     - The full binding map is read before, and after each call before the next: every command in
       the binding list with all its keys, plus what every ALT/CTRL/SHIFT/META chord of the keyboard,
       mouse buttons 1-31, the wheel and the gamepad does, so keys bound by click (bar addons'
       `CLICK ...`) are compared too; each custom command found that way is read by command as well,
       so its other keys count. A custom binding only on an input outside that list stays out of
       reach (no client call lists bound keys); it would need a Character store that differs
       there, which the measured case doesn't have.
       Unreadable or different stops there, so changed keys are never saved. Success is the set
       reading Character with the map unchanged. A thrown error or a `false` return is a failure.
     - After a stop with the account keys already saved, while Account is still active and the keys
       in memory are no longer those, the saved account keys are reloaded (`LoadBindings(Account)`,
       the same set, not a switch): otherwise Blizzard's Keybindings window or another addon saving
       the current set would write them over the account keys. The reload is verified and reported;
       in combat it doesn't run, and the report says so.
       There is no other rollback: going back is the player's untick in Settings.
     - `AltStableSyncChar.bindingSwitch` is written before the first call and removed only after a
       verified success. While it exists, a new attempt runs only if the keys are exactly as before
       the first one; otherwise it is refused with no binding call (saving changed keys as the Account
       set would lose the account keys). Step 1 then lists the keys that differ and says OK makes
       the current keys the account ones; that OK accepts exactly the keys it showed. It stays while
       the character is on Character bindings, where it blocks nothing, and `/altsync status` shows
       it only on Account bindings.
     - Step 1's OK runs only while the entry is the version it showed (a sync may have replaced it).
     - Never Character -> Account, never a set deletion, never from an event or a restore.
   - Displaced keys are shown, and both keys per command are kept in capture and restore.
9. **Macros:**
   - **Account macros are never edited, created or deleted.** Sharing them is a separate, future,
     owner-approved policy (#30).
   - Character macros travel with a loadout (included by default; "Include character macros"
     unticked, or `/altsync load <name> nomacros`, leaves their slots as they are, listed). Reuse a
     macro on a matching name + normalised body + scope (+ icon). **Update** the one character
     macro of that name when its text or icon differs (#6): shown in the preview ("An updated macro
     changes every button that uses it, on any bar"), recorded in the backup before it is stored,
     checked against the preview right before `EditMacro`, read back. Restore puts it back when it
     is as the load left it, does nothing when it is already as it was, and leaves it (named,
     partial) when the player changed it since. Create a character macro when no macro has that
     name and capacity permits. An account macro of that name, or two macros of that name: refused,
     never written. A definition whose body isn't text is damage, never an update.
   - **No macro is ever deleted** (character or account) unless the player explicitly asks.
     Capacity is never freed by deleting; a shortfall is shown before any write. A Restore lists
     the character macros the operation being undone **created** (`createdMacros` on the
     backup) as kept. **Offering to remove them is deferred** (#6, Codex): a removed macro can't be
     brought back by the restore's own backup, and a bar scan misses direct `MACRO` key bindings.
   - Macro mutations (creates, then updates) run first, each looked up by name at that moment
     (a creation shifts indices), then actions are placed. A slot's displaced content is compared
     with its backup as updated so far.
   - Duplicate macro names are refused ("rename one"); capture never uses a cursor round trip
     (capture runs at preview time and writes nothing).
   - A button never points at a missing or mismatched macro.
   - Macro bodies are never rewritten (for faction, race, locale, rank or talents).
   - A macro whose spell is not learned yet is still placed; this is reasoned, and verified in #13.
10. **Never reassign a Blizzard global.** `tests/test_taint.lua` guards this.

## Applying a loadout (the transaction)

1. Validate schema, module versions, class, readiness, combat state and an empty cursor.
2. Plan from the exact selected version against the target. Show changes, skips, explicit clears,
   the binding destination and any wider physical scope (for example "Camera preference affects
   this WoW account").
3. On confirmation, check that the version and the relevant target state still match the preview.
   Otherwise re-preview.
4. Capture an exact snapshot of everything the plan may touch, plus the active binding and layout
   context. If that fails, write nothing.
5. Create, update or reuse character macros, then rebuild the index map.
6. Write actions and bindings one at a time, reading each back. Save the explicit binding set.
7. Stop on combat, a stale dependency or a verification failure. Keep the result and the backup.
   Offer a fresh preview for what remains.
8. Report changed, skipped, failed and untouched entries truthfully. A partial result is not
   success.

Not every module can be made atomic (some need a reload). Preflight what can be proved, stop safely,
and keep restore available. A provider that can't meet capture/read-back/restore is excluded.

## Preserve intent on Save (#28)

A low-level character may Save without destroying what it can't see. The Load keeps one baseline per
kind (`AltStableSyncChar.loaded`) with the applied/skipped result.

| Capture state | Save behaviour |
|---|---|
| Supported, observable, changed | Save the current value (after preview) |
| Inherited entry was unresolvable, and the slot was not deliberately replaced | Keep the inherited entry |
| The load kept the slot free (emptied, or already empty) for an action this character can't use | Keep the inherited entry **whatever the slot holds now**: the client puts a newly learned spell in the first empty slot (#46). The Save preview, its no-op message and Save As say "holds X now: not saved". It holds until a Load places the action there; `save drop` saves the slot empty and compares with what is there |
| A kept spell captured again from a class tab | Gains `class = true` (one Save, "Marks N class spells"); a capture without the mark never removes it, including when another rank of the same spell is saved there |
| Same family on a low alt, policy "highest known" | Keep "highest known"; don't freeze the low ID. A rank update (a hunter bar after training, or the new rank dragged in) is no change |
| Deliberate downrank | Keep the exact rank |
| Inherited addon absent, or field unreadable | Keep the prior payload |
| Empty or ambiguous slot after a skipped load | Keep, unless the review chose `save drop` |
| `save drop` chosen | The entries this character couldn't use stop being part of the entry. They stay covered as empty, so a later Load empties those slots on every character (#46); the preview says so |
| Deliberate clear | A covered empty slot is a clear: a later Load empties it on every character (#46) |

**Which captured rank is deliberate** (#42). Caster bars keep an old rank after training, while hunter
bars update, so the bars alone can't show intent. A spell on the bars at **two or more ranks** is a
ladder: the highest of them on the bars is "highest known", and the lower ones are "exact". A spell at
**one rank** is "highest known", whatever the rank. Rank order is spellbook order, and the top known
rank always ranks highest. The ranks must be **on screen together** (#5): Action Bar 1's two pages and
the four stance/form pages take turns on the same buttons, so a rank left under a stance page, or on
the other page, never makes one on another page "exact"; Action Bars 2-8 show beside any of them. A lone deliberate downrank is read as "highest known"; a macro
(`/cast Heal(Rank 2)`) keeps its text as written.

On Save, a slot holding **the same rank** as after the load is unchanged, even when its policy reads
differently because other slots changed: it keeps the loaded policy, so a downrank inherited from the
main stays exact and a stale caster rank never freezes into one. A rank change of a "highest known"
spell is a rank update, not an edit, when the loaded entry also says "highest known" (changing an
entry's exact rank is an edit). A ladder built on an alt by adding a rank to another slot therefore
leaves the untouched lower rank as loaded, and Save As from a loaded entry merges the same way. To
record the rung, place the lower rank in a slot that held something else after the load: a changed
slot is saved with its captured policy. Only a character with no usable loaded record, or a merge
that refuses, gets a plain capture.

**How Save tells "unchanged" from "changed"** (#28). A completed load records `after`, a capture of
the slots, keys and character macros right after it, and `unavailable`, the slots it skipped. Save
captures again (C) and merges per slot against the baseline B and `after` A:

| C | Saved |
|---|---|
| unreadable or ambiguous | B; A stays the comparison |
| A was unreadable, at a slot the load skipped | B; A stays the comparison |
| same as A (action, plus a character macro's body and icon) | B |
| empty, and the slot was unavailable at load | B |
| anything else | C, with its captured policy |

- **Keys** are compared only against keys taken under Character bindings: at a load, or at a fresh
  Save As. A Save never sets that comparison. Under Account bindings, or with no comparison, the
  loaded keys are kept and the preview says why.
- **Two slots needing different bodies under one macro name, or one key on two commands, refuse
  the Save.** There is no renaming.
- **Modules, slots and commands this build doesn't capture are kept from B as they are** (A35).
- **No usable comparison** means a failed load, a failed post-load capture, a Restore since the
  load, or a record from an older build. Save is then refused, and Save As warns before a plain
  capture, without guessing a count. Save As does the same when the merge refuses on a clash.
- **The preview lists** each changed slot (a character macro's body or icon counts), each changed
  key, the entries kept, and with `save drop` the entries left out.
- **The preview is frozen:** the confirm re-captures and refuses on any difference. A Save then
  advances the record (baseline = saved, A = this capture, keeping the old A where C was unreadable),
  and the `unavailable` set carries forward.

**Which entry Save may replace:** only the entry this character currently has loaded
(`AltStableSyncChar.loaded[kind]`), and only while that entry's current version is still the
loaded version. A successful Save **advances that baseline** to the version it produced (with the
saved content as the new baseline), so the same character can edit and Save again. A Save As sets
the baseline to the **new** entry, so the player can keep refining what they just created. Sync receipt
never advances a character's baseline. This restriction applies to capture Saves only; Undo and
conflict resolution use their own catalog expected-version guards. Selecting an entry without loading it, or loading a different one since, leaves
only Save As. A no-op Load ("Already matches") still records the baseline, so the main character
can Load-then-Save without a write. A Save whose baseline is stale is refused, with Save As or a
refreshed Load offered instead (A39).

Save As from a loaded entry uses the same merge, so the fork keeps the inherited unavailable
content (A09). A fresh capture with no baseline can't invent spells it never saw.

**Undo my last Save** (A44): `previous` holds the content from before this account's last Save of
the entry, with `of` = the version that Save produced. It is offered only while the entry's
current version is still `of`, so it can never overwrite a newer Save that arrived from the other
account. Undoing is itself a Save: it mints a new version (a successor, so sync carries it) with
the previous content. It is not a history product.

## Differences between characters

| Situation | Behaviour |
|---|---|
| Lower rank known | Highest known rank in the verified family; deliberate downranks (a ladder of ranks, #42) stay |
| Spell not learned | Keep it in the entry; empty the destination (#46), unless the spellbook read failed; report it |
| Different racial | Don't guess an equivalent; leave it unresolved, or use a named variant |
| Alliance/Horde macro text | Keep the literal text; use named variants ("PvP - Horde") |
| Druid forms, stances, stealth | The four stance/form pages (slots 73–120) are captured and written by slot id, active or not (measured, #5). A form switch is never an edit. Which form uses which page isn't measured yet, so previews say "Stance/form page N" |
| Druid bars vs forms | Offer a separate whole UI setup ("My UI - Druid"); no form-layer editor |
| F9 should disenchant | An Enchanting variant loadout; no profession rules engine |
| Healer raid frames | Later: a raid-frame provider inside the loadout, excluded from the UI setup |
| Addon missing | Skip visibly; keep its saved payload on Save |

## UI

One compact LibGlass window (`Panel.lua`, #9), one column, smoked glass under the text so the world
doesn't show through. `/altsync` opens and closes it; `/altsync status` and every other subcommand
stay. Later shortcuts (Talent frame, macro frame, AltStable) open the same panel.

The panel is a **view and a launcher over the slash commands' flows**: every button opens the same
preview the command would, and only that preview's confirm writes. A button passes the values it reads
at the click (entry id, typed name, chosen category), and the flow fixes them in its preview, so changing
the panel afterwards can't redirect a confirm. Redraws update the panel's own widgets only and never
touch an open preview or dialog. Panel state is session-only.

**Browsing and the save target are separate.** Load acts on the browsed entry. Save acts on the **save
target**: the entry this character last loaded or saved (`AltStableSyncChar.loaded`, set by a load,
including a no-op or a failed one, by Save and by Save As). Browsing, opening a preview and cancelling
never move it. A load that fails partway makes the attempted entry the target with no usable comparison,
so Save is refused until it is loaded again: the bars are partly that entry now, and the old target must
not take a save of them.

- **Header:** "AltStableSync", the class, a close button. **Navigation:** two tabs, Loadouts and UI
  setup (gold underline on the active one), and a quieter **Backups…** link.
- **Loadouts:** a **Category** picker and a **Saved loadout** picker, our own popup lists (Forever
  documents no dropdown API; no Blizzard menus). Categories show their counts; a category a newer build
  sent shows under its raw key. Each opening starts on the save target. Each entry shows every marker that
  applies: save target (or "older version"), conflict, conflict copy, sync status.
- **Saved contents** of the browsed entry, at once, each row as tall as its lines; under them "Saved
  Oct 12, 10:52 by Karuzo-Macphisto" (the full time on hover): Action bars (saved actions), Keybindings (saved
  key presses, "Destination: Character"), Macros (character macros), Pet bars when any. It describes
  what is saved; changes are only ever shown by the planner's preview. Empty states say which: no
  loadouts for this class, none in this category, or the browsed entry was removed (said, not quietly
  replaced).
- **Load…** (the primary button; "Review changes before loading") and **Manage…** (Rename…, Delete…;
  for a conflict copy, **Resolve…** with the keep / use-theirs choices, then the resolve preview).
- **Save this character:** "Save target: Raid Healing - Holy", "Browsing another loadout doesn't change
  this target." when browsing elsewhere, a live status (a fresh `PlanSave` while open, when the bars,
  keys, macros, cursor or combat change, after a catalog write, and every 5 s as a net:
  "No unsaved changes" only when that comparison found none, and Save is then off; else why Save can't
  run), **Save…** and **Save As…** (always available out of combat). A deleted or changed target is said, and Save stays off with the reason; it is never
  redirected to the browsed entry.
- **Save As** opens our own dialog: Category (default: the save target's, else General; never the browsed
  one) and Name, checked as you type (no red text on an untouched or blank box), Review… opens the
  preview. Enter reviews, Escape cancels. **Save As always previews**, from the panel and from
  `/altsync saveas`.
- **Backups…:** the incomplete operation, the ring newest first, then the first backup. Selection follows
  the snapshot itself; **Restore…** finds its current slot at the click. An incomplete operation also
  shows in the footer with **Undo it…**.
- **UI setup:** "Saved UI setups (Edit Mode layout and settings) aren't available yet." Planned: a
  saved-setup picker; a Layout / Preferences / Addons summary; Apply, Save, Save As.
- **Footer:** the last command's message (refusals included), else the state, else the Link
  availability ("Other account online": availability only, never "in sync").
- **Buttons:** primary, secondary and disabled look different; a disabled button says why on hover
  (the reason is `Loadout.Blocked`'s: combat, readiness, something on the cursor).
- **Escape** closes only the topmost: a preview, the name dialog or a list first, then the panel.
- **After a load:** "Loaded Everyday. Changes stay on this character until you save."
- **Save** names its target explicitly ("Update Everyday?" … "Other characters keep their current
  setup until they load this version").
- **Every prompt is our own frame**, never a StaticPopup.
- **First-login offer** (#10), after readiness and out of combat, only when at least one UI setup
  exists: "Make yourself at home. Start with your saved UI preferences." When exactly one exists it
  is named; when several exist the offer says "Choose a saved UI setup" and opens the UI setup tab.
  Buttons: Not now, and Preview and apply (or Choose). Not now, opening the preview, opening the
  tab through Choose, and applying all set `onboarding.handled`, so the offer never repeats on that
  character.
- **Edge states:**

  | State | Copy |
  |---|---|
  | Combat | "Paused in combat. Review remaining changes when combat ends." |
  | Not ready | "Waiting for character data." |
  | Cursor busy | "Finish placing the item or spell on your cursor, then try again." |
  | Macro slots full | Show the shortfall before any write |
  | Stale preview | Recompute it |
  | Unknown schema | "Unsupported version", and touch nothing |
  | Nothing to change | "Already matches the selected settings." |

The storyboard (`docs/storyboard/`) and mockup (`docs/mockups/`) are design concepts, not a running
addon. This document wins where they simplify.

## UI setups: providers (#15, #16)

A provider defines capture, validation, diff, apply, verify and exact restore. It also states whether
it needs a reload and which scope it changes (character or account). Providers are plain module
functions, not a plugin framework.

- **Edit Mode** (#15): import into an **addon-owned Character layout**, never edit a shared layout in
  place. Store the layout's name and type beside the systems string. Restore the prior active layout
  by identity, not list position. It ships only if probe #29 proves create, activate, persist and
  restore after a full exit.
- **CVars** (#16): the smallest measured allowlist. Account scope is disclosed in the preview.
- **Addon settings** (#22, #23): later, provider by provider. Never assign arbitrary SavedVariables
  or another addon's profile keys. A field never has two owners (UI setup vs loadout).

If a provider isn't ready, the UI setup shows the supported subset honestly. Nothing unsupported gets
a success tick.

## Catalog sync between the owner's WoW accounts (#18)

A must for launch (owner). The catalog appears on both WoW accounts, as AltStable and GlassChat do with
LibAccountSync. **Received entries are catalog entries only; nothing is ever applied to a character.**

### The Link addon keeps LibAccountSync's key out of the transferred file

WoW writes all of one addon's SavedVariables into one file. If `AltStableSync.toc` declared
`AltStableSyncLAS`, the household key would sit inside `AltStableSync.lua`, the very file the
beta→live transfer copies, and "wipe after copy" would be too late. So the transport is a second,
tiny addon folder:
- `Plugins/Link/`, deployed and packaged as top-level `AltStableSyncLink` (AltStable's
  `move-folders` pattern);
- `## Dependencies: AltStableSync` and `## SavedVariables: AltStableSyncLAS`;
- it uses `LibAccountSync-1.0` through LibStub. The library ships in the **main** addon's
  `Libs/LibAccountSync-1.0` (`.pkgmeta` external, tag `r5`), as in AltStable: CurseForge's packager
  doesn't apply ignores to an external inside a moved folder (#66). Where the code lives doesn't
  move the key: it's written by the TOC that declares the SavedVariables;
- it holds only the sync glue.

The key lands in `AltStableSyncLink.lua`, which the transfer never touches. `AltStableSyncLAS` is
declared in exactly one TOC.

- At its own `ADDON_LOADED` (never at file scope), the Link addon does `AltStableSyncLAS =
  AltStableSyncLAS or {}`, then `LibStub("LibAccountSync-1.0"):New{ addon = "AltStableSync", store =
  function() return AltStableSyncLAS end, maxPayload = 16384, messages = true }`, and registers
  `OnMessage` right after. The store is the account-wide table, so the key persists.
- **Messages mode is required** (r5). In the default snapshot mode, a stream that completes after a
  newer one from the same sender is dropped, which would silently lose one of two entries sent back
  to back. If `Sync.messages ~= true` after `New` (an older library copy won the LibStub load), sync
  stays **disabled**, and the status says so. Messages may arrive out of order; the receive rules are
  per entry and order-independent, so no `sid` ordering is needed.
- Entries requested by one peer go back with `Sync.SendTo(guid, payload, onResult)` (r4), where
  `guid` is that peer's GUID from `Sync.Peers()`; `SendTo` is detected at call time, as the README
  asks. Manifests use `Sync.Send`.
- **r4 and r5 are Codex-reviewed but not yet run in game** (LibAccountSync status, 2026-10-07); r3 is
  the last release validated with two accounts. The two-account rehearsal (#18, #13) therefore also
  validates the library, and any library defect it finds goes to a LibAccountSync issue, never an
  edit here. It includes a catalog with **100 differing entries**, to check that the manifests
  eventually agree after retries.
- It starts only after core reports a usable DB. A refused schema disables sync too.
- It is an ordinary enabled addon (not LoadOnDemand), with a visible linked/disabled status.

### Messages

- **One preset** as an envelope: CBOR→Deflate→Base64, plus schema and checksum (`Envelope.lua`, the M1
  part of #17), including `ancestors`, **minus `previous`**.
- Or **a manifest batch** `{ [id] = version }` of at most 100 ids. It lists every entry: live,
  tombstones and conflict copies.
- Every encoded message is size-checked. An oversized entry is reported and stays local.
- **Manifest exchange** runs:
  - on peer sighting;
  - after every local catalog write;
  - on a bounded timer while a peer is linked (there is no delivery ack, so "sent" is not "synced");
  - on a manual **Refresh**.

  Each exchange requests every entry that still differs, including entries whose messages the
  library refused under its messages-mode limits (4 open streams per sender, a 256-message overtake
  window). Messages mode is not guaranteed delivery; repeated exchange is the recovery, and an entry
  stays "pending" until the manifests match.

  To keep the recovery from flooding those limits: catalog mutations trigger an exchange only when
  they are **local**, coalesced within 2 seconds, and receipts never do. The other triggers above
  (peer sighting, the timer every 120 s, Refresh) remain. Each side **pulls**: it requests what it
  lacks from the other's manifest, and nothing is pushed. A request names **one id**; at most 3 are
  outstanding per peer, and one completes when its entry arrives or after 30 seconds, when it goes
  back in the queue while still lacking. So an entry is never requested twice at once, and an id the
  peer never answers costs at most 3 requests per 30 seconds.
- **Wire schema 3** (#46; 2 was #5): every message kind carries `s = 3`. An older build sends and
  accepts only its own, so sync between an updated and a not-yet-updated account **pauses** both
  ways: the updated side says so once and its Link status shows "sync paused"; the old side shows
  entries as pending. (A schema-2 build would save auto-placed spells over kept gaps and drop class
  marks, then publish that as a normal successor.) Update both accounts together.
- **Wire format** (`Plugins/Link/Sync.lua`): `MAN\n<envelope>` (manifest batch
  `{ b = session, c = counter, p = part, n = parts, l = { [id] = version } }`), `REQ\n<envelope>`
  (`{ i = id }`, sent to one peer) and `ENT\n<id>\n<version>\n<envelope>` (one entry, sent to the
  peer that asked; id and version outside the envelope match even a refused answer to ITS request
  only, and that exact version is not asked for again this session; content that doesn't match them
  is refused). The envelope is
  `"ASE1:<Adler-32 of the CBOR, as two 16-bit hex halves>:<Base64(Deflate(CBOR))>"`. The size check
  is on the whole string handed to the library; batches shrink 100 → 50 → 25 ids until each fits.
  Manifests are ordered per peer session by counter: an older one arriving late, or a stray part of
  one, changes nothing. Sessions are ordered by the library's `sid`, which grows per sender across
  reloads: a session first seen with a lower `sid` than the current one's is an old one arriving
  late and is ignored; a higher one replaces the current session (the peer reloaded).
- **Which peers count.** LibAccountSync lists every online account of the owner, with the Link
  addon or not. A peer counts for "confirmed" and status only once it has sent a message; until
  then `/altsync link` names it as "no reply yet". A manifest no peer took (one still
  mid-handshake) is sent again 5 seconds later. A peer that leaves takes its queue and requests
  with it.
- **Commands** (catalog only, each previewed with the id and version it shows; stale is refused):
  `/altsync list` (every category of this class, with ids and pending / confirmed / conflict
  markers), `rename <id|name> <new name>`, `delete <id|name>`, `conflicts`, `resolve <id|name>
  theirs|mine` ("theirs" on a deletion conflict means delete here too), and `/altsync link
  [refresh|on|off]`. A name works only when exactly one entry has it, since sync can bring two
  entries with one name (for `rename`, only a one-word name).
- **Nothing hides (#39).**
  - `link off` persists across logins. So while it is off, every successful `saveas`, `rename`,
    `delete` and `resolve` adds "Link is off: your other account won't see this until /altsync
    link on." after its result. If the Link addon is installed but failed to start, the line says
    "Link isn't running (<why>)" instead. A refusal, including a stale one at the confirm, adds
    nothing, and so does a missing Link addon.
  - `conflicts` lists this class's copies, which are the only ones this character can resolve. It
    adds one line counting every other open copy: other classes' loadouts, and UI setups. That is
    the same set `/altsync link` counts (`Catalog.Conflicts()`).

### Receive rules (per entry, idempotent)

Each version carries `ancestors`, the last 20 versions it descends from. That makes ordinary lag (B
offline while A saved three times) a plain fast-forward rather than a conflict.

| Incoming | Action |
|---|---|
| Same version as local | ignore |
| A live conflict copy (`<id>~<v>`) whose `v` our root `<id>` already holds or has moved past | ignore. It is the other account's copy of **our** content. Retired copies (tombstones) still propagate, which is how a resolution settles both accounts |
| Incoming version is in local `ancestors` (older than what we hold) | ignore |
| Local version is in incoming `ancestors`, or the id is unknown | **replace** (fast-forward). Local `previous` is untouched; it is local Save recovery only |
| Anything else (both accounts saved from a common version, or the lag exceeded 20 saves) | **divergent**: keep the local entry; store the incoming one whole as conflict copy `<id>~<incoming version>`, named "<name> (from <char>)", with a one-line notice. If that conflict id already exists, live **or tombstoned**, ignore it |
| Unknown or newer envelope schema | reject; local untouched |
| Older envelope schema (an older build: 1-12 #5, or #5's wire 2) | reject, nothing imported or remembered as refused; that peer shows "sync paused" until it updates, then the same versions are fetched |

- **Resolving a conflict settles both accounts.** The conflict copy offers **Keep this version** and
  **Keep mine**. Either one mints a new version of `<id>`: its content is the chosen version
  **whole** (content, name and provenance), and its `ancestors` hold **both** competing versions
  first, then both branches' history. Every stored live conflict copy whose version that root now
  holds or descends from is **retired** (a tombstone descending from the copy). That covers the
  chosen copy and any older copies from the same branch. The other account does the same when it
  fast-forwards to the resolution, which retires its mirror copy. A late-arriving copy or older
  message is ignored, because its version is in the root's history. **Deleting a conflict copy is "Keep mine"** (the same resolution, so the
  roots still converge); there is no way to discard a copy without resolving. The entry shows
  "conflict" until it is resolved, and that status takes precedence over "confirmed".
- **Deletion conflicts:**
  - Tombstone over tombstone: a successor fast-forwards as usual. Two incomparable tombstones
    (offline deletes on both sides) are equivalent; both accounts keep the **lexically greater
    version token**, a tie-break used only here, so the roots converge and confirm.
  - Deleted here, edited there: the edit arrives as a live conflict copy. **Keep this version**
    saves the copy's content as an ordinary entry under a new id (a Save As) **and** mints a
    successor tombstone for the root descending from both versions, retiring both mirror copies as
    above. The root stays deleted, the edit survives, and the other account fast-forwards.
  - Edited here, deleted there: the tombstone arrives as a tombstoned conflict copy with the notice
    "deleted on <char>". **Delete here too** tombstones the root, descending from both versions;
    **Keep mine** mints a live version descending from both (the only way a live version may
    descend from a tombstone).
- There is no field merging, ever.
- **Accepted edge case:** when two incomparable tombstones meet, the losing one's history is dropped
  (the tie-break keeps one whole version). A delayed older message from that losing branch can then
  arrive as one extra conflict copy, even though that account had already deleted the entry. The
  root stays deleted, and resolving the copy ("keep it deleted") settles it. This is preferred over
  adding history-merging machinery for a rare, visible, harmless case.
- **Delete is a versioned tombstone** with ancestors, kept indefinitely so a stale peer can't
  resurrect the entry. Tombstones can't be edited or recovered from the UI. An edit made without
  seeing the deletion (its ancestors don't include the tombstone) is divergent and follows the
  deletion-conflict rules above, so nothing resurrects or vanishes silently.
- `Replace`, `Rename`, `Delete`, Undo and the conflict actions all take an **expected version** and
  refuse when it's stale. A newer version that arrived from the other account is therefore never
  overwritten or tombstoned unreviewed.
- **Confirmed** means the peer's manifest lists exactly our current `{id, version}`. Until then
  the status says "pending"; an unresolved conflict shows "conflict" instead.
- Sync is same-flavour only, by the library's design. Beta → live is the file transfer.

## Beta → live (Nov 4)

- **`Tools/Transfer-Profiles.ps1 -From <beta Account dir> -To <live Account dir>`** (#12):
  - copies **only** `SavedVariables\AltStableSync.lua`, never `AltStableSyncLink.lua`, and never copies
    or replaces a destination Link store;
  - refuses a source that **assigns a value** to `AltStableSyncLAS`: any line starting
    `AltStableSyncLAS = ` other than `AltStableSyncLAS = nil`. The client writes `= nil` for a
    declared but unset variable, and today's beta files contain exactly that line (a line-level
    text check, not Lua parsing);
  - refuses a source with no `AltStableSyncDB = ` line (not this addon's file; it only identifies
    the file, and the addon validates the content on load);
  - reads the source **once**: the bytes checked are the bytes hashed and written, never re-encoded;
  - requires the destination `WTF\Account\<id>\SavedVariables` folder to exist already, and never
    creates it. On a fresh live install, log each live account in once and exit before transferring;
  - refuses `-From` and `-To` in the same WoW folder (a scope rule for a beta → live tool, not flavour
    detection);
  - is run once per live WoW account that should start with the catalog;
  - refuses while any `Wow*` process runs, checked again just before the commit (two checks aren't
    a lock, so every client stays closed throughout);
  - refuses if the destination file exists. `-Force` **replaces** the whole live catalog and its
    account-wide backups, never merges, after keeping a verified `.pre-transfer-<time>` copy;
  - stages a verified temp file, then commits with a rename that never overwrites
    (`File.Move`), or `File.Replace` for `-Force` (never `Move-Item -Force`, which deletes first),
    then reads the result back by SHA-256;
  - real transfers run on **Windows only**: .NET's non-overwriting move on Unix can overwrite a
    file that appears at the last moment;
  - exits 0 done, 1 refused before any write, 2 failed after the write phase began, with the state
    and the backup's recovery line printed;
  - has `-WhatIf` (a read-only preflight) and a self-test (`tests/run.ps1` and CI run it).
- **No flavour fingerprint, no quarantine.** Backups are keyed by GUID, and live GUIDs differ, so
  beta backups are inert on live. They stay as dead data, and cleanup is deferred. `origin` is
  provenance only (#11). `WOW_PROJECT_ID` or build changes never trigger anything.
  `AltStableSyncChar` never travels; per-character files aren't copied, so every live character
  starts fresh.
- Beta entries may reference spells, macros, CVars or layouts that are unavailable on live. The
  explicit preview at Load/Apply handles that; provenance never grants permission.
- **First login on live:** the normal first-login offer, if a UI setup exists. No writes.
- **Launch gate** (`docs/RUNBOOK.md`): load on one character, load on a second character, full
  exit, compare both.

## Scope, order and cuts

**Order** (expose the write/restore risk first):
1. P0: this design and the backlog.
2. P1: the catalog (#27). The probe (#29) runs in parallel.
3. P2: the vertical slice (#4): one action, one binding and one character macro, with a minimal
   preview/confirm, backup, apply, exact restore and a full-exit rehearsal.
4. P1b: the Link addon and envelope (#18, #17).
5. P3: adaptive loading and preserve-intent (#5, #6, #7, #28).
6. The rest of the UI (#9) and the first-login offer (#10).
7. The transfer script (#12).
8. The rehearsal (#13).

#15 and #16 ship only if #29 passes in time. If they miss, this document's UI-setup promise is
revised explicitly.

**Cut first if time slips:** contextual buttons, first-login polish, addon adapters, optional
providers, richer history, optional integrations. **Never cut:** preview, backup, exact restore,
schema refusal, readiness and combat gates, macro ownership, read-back, or catalog sync (owner).

## Review record

- **2026-10-06, original plan:** Codex review (medium). It established adaptive apply vs exact
  restore, macro ownership and reindexing, cursor hygiene, an explicit binding set, readiness gating,
  opaque ids, and the vertical slice first. The full verdict is on issue #1.
- **2026-10-08, pivot plan:** Codex review (medium) and three rounds with gpt-6-astra (high), ending in
  **consensus**. Accepted:
  - ancestry versions (`writer:seq` + `parent`) instead of numeric revs, which collided across
    offline accounts;
  - a per-session writer token, because a stored one is copied along with the file;
  - deterministic, idempotent conflict copies, which honour their tombstones;
  - permanent tombstones;
  - expected-version guards on every destructive catalog operation;
  - ignoring a stale predecessor;
  - a local-only `previous`;
  - bounded, size-checked manifests with a timer, Refresh and pending status;
  - the Link addon for LAS isolation;
  - resume only by a new preview;
  - stale-preview refusal;
  - Save over a loaded entry disabled until #28;
  - P2 before the Link;
  - verification by trigger/write matrix rather than keyword absence.

  Rejected: nothing material.
- **2026-10-08, `/code-review xhigh 31`** (Claude) found 15 issues the rounds above missed. All were
  accepted:
  - Save restricted to the entry this character loaded, at its loaded version (disabled until #28);
  - a bounded `ancestors` list (20) so lag fast-forwards;
  - conflict resolution that mints a version descending from both sides, so it settles;
  - Undo as a guarded new Save;
  - one backup per operation, with retries reusing it and a ring of 10;
  - displaced cursor payloads verified and cleared;
  - bindings written to the Character set only;
  - a predicate readiness gate, with the `/reload` order to be measured (#29);
  - the transfer refusing only a non-nil `AltStableSyncLAS`, requiring an existing destination, and
    running per account;
  - no macro deletion;
  - `AltStableSyncLAS` initialised at the Link addon's `ADDON_LOADED`;
  - tombstone wording consistent with the table;
  - a pre-#28 Save As warning;
  - the first-login offer marked handled on every outcome, choosing a setup when there are several.
- **2026-10-08, PR rounds (gpt-6-astra, high):**
  - Round 1 reached consensus on the first draft.
  - Round 2, on the xhigh fixes, accepted four more: the operation backup is pinned while
    interrupted, with resumes still backing up; a Save advances its own baseline, and the
    loaded-entry rule covers capture Saves only; resolution tombstones both mirror copies; and
    deletion conflicts are defined (two tombstones are equivalent, plus the delete/edit cases).
  - Simplification accepted: "confirmed" means an exact root match.
  - Round 3 accepted two more: incomparable tombstones converge on the lexically greater version
    token, and a successor tombstone fast-forwards; and "Keep this version" on the deleted side also
    mints a successor tombstone for the root.
  - Round 4: **consensus**, plus one nit (A44 states the Undo condition).
- **2026-10-08, pinned LibAccountSync `r5`** (released 2026-10-07). It requires `messages = true`, because
  snapshot mode could drop one of two back-to-back entries. Replies use `SendTo`. r4 and r5 are not
  yet validated in game. A focused gpt-6-astra (high) round reached **consensus**. Its nits are
  applied: the GUID comes from `Sync.Peers()`, retries cover refused messages, and the rehearsal
  includes 100 entries.
- **2026-10-08, `/code-review high 31`** (Claude) raised 10 candidates; all accepted:
  - deleting a conflict copy now counts as "Keep mine", so the roots still converge;
  - explicit backup slots: `ring`, `firstSeen`, and an `operation` slot for the interrupted
    operation, with one interrupted operation per character;
  - Save As sets the baseline to the new entry;
  - exchanges are triggered by local writes only, coalesced, with a 30-second request hold-off and
    at most 3 requests in flight per peer;
  - `AltStableSyncChar.schema`, refused when newer;
  - Restore offers, visibly, to remove the macros the undone load created;
  - the mockup's differences from this design are listed in its README;
  - stale wording fixed in the `.pkgmeta` comment, the codex-consult skill, the AGENTS docs list and
    a `test_core` fixture.
  - Confirming round (gpt-6-astra, high): `createdMacros` moves onto the backup snapshot itself, so
    Restore can still remove what a completed or abandoned load created. The exchange-trigger
    wording is fixed, and `AltStableSyncChar` initialisation at schema 2 is specified. The next
    round removed a "stamp a populated unschemed char table" exception: only a missing or empty one
    is initialised; anything else unschemed is refused untouched.
- **2026-10-08, #27 implementation:** the two-account tests found that a live conflict copy synced
  to the other account became a second, redundant copy there (a copy of that account's own version).
  The fix is a new receive row: a live conflict copy is ignored when our root already holds its
  version or a successor.
- **2026-10-08, PR #32 round 1 (gpt-6-astra, high):** four code defects, all fixed:
  - "Keep this version" now takes the chosen version whole, including its name and provenance;
  - a copy left live because it was edited again before resolving is now retired, by retiring
    covered copies on fast-forward and on resolve;
  - the resolution keeps both branches' history, so a delayed older message can't reopen it;
  - a schema-1 DB holding `presets` is refused rather than mutated.

  Simplification: the explicit "tombstone the mirror id we never received" step was redundant once
  covered copies are retired, so it was removed.
- **PR #32 round 2:** a "deleted there" conflict copy stays resolvable after the entry is deleted
  here too ("keep it deleted", in either writer-token order).
- **PR #32 round 3: consensus.** Nits applied: a stale-resolution test, and the tombstone
  tie-break edge case is documented.
- **PR #32, posted Codex review + three confirming rounds (gpt-6-astra, high):**
  - **Receive boundary:** it now rejects entries whose read fields have the wrong type (`conflict`,
    `deleted`, `name`, `modules`, ...). Loadouts must carry non-empty class and category strings (any
    key: forward compatible). A conflict copy's id must be `<of>~<version>`, which rules out
    self-reference.
  - **Keeping an edit of a deleted entry:** it takes the caller's name, or the first free
    "(kept)"/"(kept N)" name, and preserves the received class/category keys.
  - **Consensus reached.
