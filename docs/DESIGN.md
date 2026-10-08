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
`docs/forever-api-notes.md` (this addon) and `C:\Projects\References\PORTING-TBC-TO-FOREVER.md`
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
  switching back deletes the character set. **This addon never switches sets.**
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
  (unless the entry deliberately holds a lower rank), and leaves unresolvable entries untouched,
  reporting each one.
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
  schema = 2,                       -- #27 upgrades 1 -> 2; an unknown or newer schema is refused untouched
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
      modules = { actions = {...}, bindings = {...}, macros = {...} }   -- loadout
             or { editmode = {...}, cvars = {...} },                    -- UI setup
      previous = { of = version, modules, updated },  -- LOCAL "undo my last Save": the content before the Save
                                               -- that produced version `of`; never sent, untouched by sync
      deleted = true,                          -- a versioned tombstone: no modules, kept indefinitely
      conflict = { of = "<id>", from = "Other-Char" },   -- a divergent copy kept whole
    },
  },
  backups = { [guid] = { <ring of 10>, pinned = <first-seen snapshot> } },  -- exact runtime snapshots
  origin = { build, region, project },         -- provenance only; never a migration trigger
}

AltStableSyncChar = {               -- per character
  lastSelected = { ui = id, loadout = { category = "discipline", id = id } },
  loaded = {                        -- ONE baseline per kind: the last Load/Apply, for #28
    ui = { id, version, baseline = <modules as loaded>, result = { applied = {...}, skipped = {...} } },
    loadout = { ... },
  },
  onboarding = { handled = true },  -- set by Not now, by opening the offer's preview, or by applying
  interrupted = { id, version, done = {...}, remaining = {...} },   -- resuming = a NEW preview + click
}

AltStableSyncLAS = <LibAccountSync store only>   -- declared ONLY by AltStableSyncLink.toc (below)
```

- **No stored writer id.** A writer token is a fresh random 12-hex string generated on every
  successful init and held in memory, with `seq` counting within the session. A stored id would be
  copied along with the file to both live accounts and reopen version collisions.
- **Schema 1 → 2** (#27): validate everything first. A schema-1 DB whose `profiles` is a table with
  `next(profiles) == nil` is stamped 2 and `profiles` is dropped, keeping `backups`. A populated or
  malformed schema 1 is refused untouched; the addon never wrote a profile, so none should exist.
  There is no migration framework.
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
| Interruption (combat starts mid-apply) | no | stops writing. Resuming = a new preview + a new click |
| Save / Save As / Delete / Recover / Keep-this-version (confirmed) | **yes** | no |
| Catalog sync receipt (#18) | **yes**, by the receive rules | **no**, ever |
| Beta → live transfer script (#12) | copies the file, client closed | **no** |

## Safety model (non-negotiable)

1. **Backup before every apply, every resume and every restore.** If capturing the backup fails,
   nothing is written. A no-op plan needs no backup. While an operation is `interrupted`, its
   **original backup is pinned** (never evicted) until the operation completes or the player
   abandons it, so resumes can't push out the real before-state; each resume still takes its own
   backup, which keeps any edits the player made in between. The ring holds 10 per character, plus
   the pinned first-seen snapshot.
2. **Preview before write**, in our own frame. The preview captures an **immutable copy of the entry
   and its version**. Confirming applies exactly that copy, or refuses as stale if the entry, or the
   target state the plan relied on, changed since (A38).
3. **No clear-before-import.**
   - Each write is read back. An unresolvable entry (spell not learned, item not owned, foreign
     racial) leaves its destination untouched, and stays in the saved entry.
   - The player loads or retries **explicitly**; nothing retries on an event.
   - An empty slot in the saved entry is not an instruction to erase the destination. Clearing is a
     deliberate choice shown in the preview.
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
   planning. Unknown or newer schemas are refused, at startup and in received envelopes.
7. **Ranks:** keep the original ID plus name. Adaptive load uses the highest known rank in the
   same-name family where the entry says "highest known". A deliberate low rank stays exact. Exact
   restore never upgrades. Ambiguous or cross-locale mappings are deferred, never guessed.
8. **Bindings are written to the Character set only, and only when it is the active set.** The
   preview shows "Destination: Character".
   - If the character uses Account bindings, the binding part is blocked with "Enable
     character-specific keybindings in WoW settings, then try again." The Account set is never
     written (it is shared by every Account-binding character on the WoW account). **Never switch
     sets.**
   - Displaced keys are shown, and both keys per command are kept in capture and restore.
9. **Macros:**
   - **Account macros are never edited, created or deleted.** Sharing them is a separate, future,
     owner-approved policy (#30).
   - Character macros travel with a loadout (included by default). Reuse a macro only on a matching
     name + normalised body + scope; otherwise create a character macro after checking capacity.
   - **No macro is ever deleted** (character or account) unless the player explicitly asks.
     Capacity is never freed by deleting; a shortfall is shown before any write.
   - Macro mutations run first, then the name/body→index map is rebuilt, then actions are placed.
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
5. Create or reuse character macros, then rebuild the index map.
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
| Same family on a low alt, policy "highest known" | Keep "highest known"; don't freeze the low ID |
| Deliberate downrank | Keep the exact rank |
| Inherited addon absent, or field unreadable | Keep the prior payload |
| Empty or ambiguous slot after a skipped load | Keep, unless an explicit clear was chosen in review |
| Explicit clear chosen | Store the clear; later previews show the deletion |

**Which entry Save may replace:** only the entry this character currently has loaded
(`AltStableSyncChar.loaded[kind]`), and only while that entry's current version is still the
loaded version. A successful Save **advances that baseline** to the version it produced (with the
saved content as the new baseline), so the same character can edit and Save again. Sync receipt
never advances a character's baseline. This restriction applies to capture Saves only; Undo and
conflict resolution use their own catalog expected-version guards. Selecting an entry without loading it, or loading a different one since, leaves
only Save As. A no-op Load ("Already matches") still records the baseline, so the main character
can Load-then-Save without a write. A Save whose baseline is stale is refused, with Save As or a
refreshed Load offered instead (A39).

Save As from a loaded entry copies its inherited unavailable content (after #28). A fresh capture
with no baseline can't invent spells it never saw. **Until #28 lands, Save is disabled entirely and
Save As is a fresh capture.** Its preview warns: "N entries from the loaded setup aren't available
on this character and won't be kept."

**Undo my last Save** (A44): `previous` holds the content from before this account's last Save of
the entry, with `of` = the version that Save produced. It is offered only while the entry's
current version is still `of`, so it can never overwrite a newer Save that arrived from the other
account. Undoing is itself a Save: it mints a new version (a successor, so sync carries it) with
the previous content. It is not a history product.

## Differences between characters

| Situation | Behaviour |
|---|---|
| Lower rank known | Highest known rank in the verified family; deliberate downranks stay |
| Spell not learned | Keep it in the entry; leave the destination untouched; report it |
| Different racial | Don't guess an equivalent; leave it unresolved, or use a named variant |
| Alliance/Horde macro text | Keep the literal text; use named variants ("PvP - Horde") |
| Druid forms | Capture the verified underlying form pages, including inactive ones (#29). A form switch is never an edit |
| Druid bars vs forms | Offer a separate whole UI setup ("My UI - Druid"); no form-layer editor |
| F9 should disenchant | An Enchanting variant loadout; no profession rules engine |
| Healer raid frames | Later: a raid-frame provider inside the loadout, excluded from the UI setup |
| Addon missing | Skip visibly; keep its saved payload on Save |

## UI

One small LibGlass window with **UI setup** and **Loadouts** tabs and a quiet **Backups** link (#9).
`/altsync` opens it. Later shortcuts (Talent frame, macro frame, AltStable) open the same panel.

- **Header:** "AltStableSync" and the character's class.
- **Loadouts tab:** a category dropdown (player's choice) and a saved-loadout dropdown (that list only).
  Then a summary of actions, bindings ("Destination: Character"), "Include character macros", and the
  buttons Load, Save, Save As.
- **UI setup tab:** a saved-setup dropdown; a Layout / Preferences / Addons summary with an "Included
  settings" expander; the buttons Apply, Save, Save As.
- **Choosing a dropdown entry never loads it.** After a load: "Loaded Everyday. Changes stay on this
  character until you save."
- **Save** names its target explicitly ("Update Everyday?" … "Other characters keep their current
  setup until they load this version"). Save As shows the destination category and checks the name
  inline.
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
- it embeds `Libs/LibAccountSync-1.0` (`.pkgmeta` external, tag `r5`);
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

### Receive rules (per entry, idempotent)

Each version carries `ancestors`, the last 20 versions it descends from. That makes ordinary lag (B
offline while A saved three times) a plain fast-forward rather than a conflict.

| Incoming | Action |
|---|---|
| Same version as local | ignore |
| Incoming version is in local `ancestors` (older than what we hold) | ignore |
| Local version is in incoming `ancestors`, or the id is unknown | **replace** (fast-forward). Local `previous` is untouched; it is local Save recovery only |
| Anything else (both accounts saved from a common version, or the lag exceeded 20 saves) | **divergent**: keep the local entry; store the incoming one whole as conflict copy `<id>~<incoming version>`, named "<name> (from <char>)", with a one-line notice. If that conflict id already exists, live **or tombstoned**, ignore it |
| Unknown or newer envelope schema | reject; local untouched |

- **Resolving a conflict settles both accounts.** The conflict copy offers **Keep this version** and
  **Keep mine**. Either one mints a new version of `<id>` whose content is the chosen one and whose
  `ancestors` include **both** competing versions. It also tombstones **both** deterministic copy ids
  for those two versions, `<id>~<a>` and `<id>~<b>`, including the mirror copy this account never
  received. Each tombstone descends from its copy's version. The other account then fast-forwards
  the root and its own mirror copy, and a late-arriving copy is ignored because its id already
  exists as a tombstone. Deleting a conflict copy alone only removes the copy. The entry shows
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
  - requires the destination `WTF\Account\<id>\SavedVariables` folder to exist already. On a fresh
    live install, log each live account in once and exit before transferring;
  - is run once per live WoW account that should start with the catalog;
  - refuses while any `Wow*.exe` runs, checked again just before writing;
  - refuses if the destination file exists (`-Force` backs it up first);
  - copies to a temp file, then moves it into place;
  - has `-WhatIf` and a self-test.
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
