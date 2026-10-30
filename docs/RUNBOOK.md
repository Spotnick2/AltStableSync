# Runbook

Operational notes for working on AltStableSync against a WoW: Forever client. The *why* lives in
`docs/DESIGN.md`; this is the *how*.

## Install and paths

The beta is `C:\Program Files (x86)\World of Warcraft\_classic_beta_` (executable `WowB.exe`).
**Live Forever** is `C:\Program Files (x86)\World of Warcraft\_forever_` (Battle.net product `wowf`,
executable `Wow.exe`), pre-installed on 2026-10-14 at 1.60.1.70245 for the stress test. It has no
`WTF` or `Interface\AddOns` folder until its first launch. Its layout is expected to match the
beta's below; the stress test confirms it. Every script still takes an explicit path.

Measured on the beta, account `50284074#1`:

```
_classic_beta_\Interface\AddOns\AltStableSync\                         the deployed addon
_classic_beta_\WTF\Account\<id>\SavedVariables\AltStableSync.lua         account-wide catalog + backups
_classic_beta_\WTF\Account\<id>\SavedVariables\AltStableSyncLink.lua     LibAccountSync store (#18), never copied
_classic_beta_\WTF\Account\<id>\<realmID>\<Name>-<Surname>\SavedVariables\AltStableSync.lua
                                                                         per character (AltStableSyncChar)
_classic_beta_\WTF\Account\<id>\bindings-cache.wtf, macros-cache.txt,
    edit-mode-cache-account.txt                                          server-side caches, per flavour
```

The realm folder is a numeric id (`70`); character folders carry the surname. Blizzard's own
server-side caches are per flavour: they will **not** follow the player from beta to live, which is
the whole point of this addon on day one.

## The in-game loop

1. `pwsh Tools/deploy.ps1` (`-AddOnsPath` for another flavour).
2. In game: `/console scriptErrors 1` once (errors are off by default), BugSack recommended.
3. `/reload`, then `/altsync` — it prints version, schema and counts.

## The audit procedure (#95)

`pwsh Tools/deploy-probe.ps1`, `/reload`, then `/fp steps sync audit`: a UI setup and a loadout
applied, a full exit, both restored by name from Backups…, a second full exit, and the short checks.
The panel says what to do at each step; what each check proves and the expected residual differences
are in `docs/AUDIT.md` section 5. The results are read from the SavedVariables files afterwards.

## Verifying persistence

`/reload` proves nothing about persistence — the process and its Lua state survive it. To prove a
write: **Exit Game**, wait for `WowB.exe` (live: `Wow.exe`) to go, relaunch, and check the value in game or in the
file. SavedVariables are written only on a clean logout/exit or `/reload`. **Close the client
before editing or copying any SavedVariables file**, or the client overwrites it on exit.

## When the client updates

See `.claude/skills/client-update/SKILL.md`. The API dump itself is taken from the AltStable repo.

## Full-exit proof

A claim that something persisted (a loaded loadout, a restored backup, a saved catalog entry, a
binding set) needs: note the values, **Exit Game**, wait for `WowB.exe` (live: `Wow.exe`) to go, relaunch, log the same
character in, compare. Record the build, the character (class, race, faction, level) and what was
compared. A `/reload`, a stub test or the HTML mockup is never that proof.

## Saving from a lower-level character

Load an entry on a low-level alt: the bars end up looking like the loadout. A slot whose class spell
or item the alt doesn't have yet is emptied (the preview lists each one with its reason), and so is a
slot the loadout leaves empty. Professions and racials the alt doesn't have leave their slot alone.
`/altsync restore 1` puts the bars back as they were.

New spells the alt learns land in the first empty slot, often one of those gaps. Save doesn't take
them over the loadout's spell; it says "holds X now: not saved". Move the new spell to a slot of
your own, or load the loadout again once the alt can use the spell. Loadouts saved before schema 5
have no class marks yet: save them once on a character that knows the spells.

`/altsync save` (over the entry this character loaded) and `/altsync saveas` both keep the
inherited entries the alt couldn't load (A07–A11 in `docs/ACCEPTANCE.md`). The Save preview lists
them. `/altsync save drop` leaves them out of the entry instead: those slots are then saved as
empty, so a later Load empties them on every character (the preview says so).

Save needs a **completed** load to compare against. After an interrupted load, load again first;
Save As still works, but it warns that it captures the character as it is.

## Character keybindings

A loadout with keys, loaded on a character that uses your account keybindings, first asks to turn
on character keybindings (OK / Cancel). OK makes this character's keys an exact copy of the account
ones and also saves the current keys as your account keybindings. A moment later step 2 shows the
usual load preview; click Load there. To go back, untick Character Specific Keybindings in Settings (that deletes the character's own
keys). If the switch stops partway, it says why; it refuses to try again until the keys are as
they were, and `/altsync status` shows it.

## Macros

A loadout carries the character macros its bars use. Loading it on a character that has a character
macro of the same name with other text or another icon **updates that macro** (the preview lists
it, with the first line that changes): every button that uses it, on any bar, then shows the new
text. That is how a macro you changed and saved on one character reaches the others. `/altsync
restore 1` puts the old text back, unless you have changed the macro again since (then it is left,
and the restore says so).

Account macros are never written. A loadout's macro is left out (its slots unchanged, listed) when
an account macro has its name, when two macros share its name (rename one), or when you untick
"Include character macros" in the Load preview (`/altsync load <name> nomacros` does the same).
Macros a load created stay after a restore; delete them yourself if you don't want them.

## Bars, stances and forms

A loadout's actions cover Action Bars 1–8 (both pages of Action Bar 1) and the four stance/form pages,
hidden bars included (measured on 70291, #5). Its **keys** cover Action Bar 1's buttons
(`ACTIONBUTTON1–12`) and the pet bar's (`BONUSACTIONBUTTON1–10`, "Pet bar button 1–10" in the preview,
#47); keys for the other bars come with #7. Saving a loadout made before the pet keys adds this
character's pet keys and lists them as added. If the last Load was by a build without them, Save keeps
the loadout's pet keys and says to load it again first. Stance and form pages are written by slot whatever form the
character is in; changing form never saves or loads anything. The preview names them "Stance/form
page 1–4" until a character with forms measures which is which (`/syncprobe bars <label>` in each
form).

**The pet bar** (#47): a loadout keeps one pet bar per pet family (Bear, Imp, ...). A Load changes
only the bar of the pet that is out, and nothing happens when another pet is summoned: load again
with that pet out. Abilities match across ranks; one this pet doesn't have empties its slot, and the
loadout keeps it for pets that do. Attack, Follow, the stances and the other commands are moved,
never removed. Autocast stays as the game has it. If a pet bar write stops, the message says which
pet slot to drop the cursor into. Restoring a backup's pet bar needs the same pet out.

A loadout saved before this version covers Action Bar 1 only. The first `/altsync save` over it
after a load adds the other bars ("Adds N slots this loadout didn't cover yet"); the next one is
"Already saved".

**Update both accounts together.** This version speaks sync schema 3. While one account is still on
the old version, sync pauses both ways and `/altsync link` on the updated one says "sync paused".

## Edit Mode layouts between accounts (by hand)

AltStableSync doesn't carry Edit Mode layouts between your WoW accounts (that is #58, after launch).
Edit Mode's own share string does it. With both clients open:

1. On the account that has the layout: Edit Mode, the layout's menu, **Share**, then copy the string.
2. On the other account: Edit Mode, the layout menu's **Import**, paste, name it, pick Account or Character.

**Importing an Account layout moves other characters.** A character's layout choice is stored as a
position in the list, and a new Account layout goes in ahead of every Character layout. That was
measured for an addon's add on 70338 (#29); Edit Mode's import inserts the same way, so expect the
same. So each character on that account that uses a Character layout is on a different layout at its
next login: pick it again in Edit Mode. To replace a layout, import the new one, then delete the old
one; each step moves those characters again.

## Transfer (beta → live, #12)

`Tools/Transfer-Profiles.ps1` copies one file, `WTF\Account\<id>\SavedVariables\AltStableSync.lua`
(the catalog and the account's backups), from a beta account to a live one. Never
`AltStableSyncLink.lua` (LibAccountSync's store, which must never cross flavours) and never a
per-character file. Run it on Windows, with `pwsh` 7.

It refuses, writing nothing, when:

- a WoW client is running (any `Wow*` process): close them all and keep them closed until it finishes;
- the source assigns a value to `AltStableSyncLAS` (`= nil` is fine). Only an older version wrote
  it there: log in on beta once with the current version and exit, and the client rewrites the file
  without it;
- the source isn't AltStableSync's file, or is empty;
- the live `SavedVariables` folder doesn't exist: log that live account in once and exit;
- `-From` and `-To` are the same folder, or in the same WoW folder;
- a live `AltStableSync.lua` already exists.

**`-Force` replaces the whole live catalog and its backups; it never merges.** It first keeps the
live file as `AltStableSync.lua.pre-transfer-<time>`, verified. To put it back:
`Copy-Item -LiteralPath '<that file>' -Destination '<live>\WTF\Account\<id>\SavedVariables\AltStableSync.lua' -Force`.
Merging into an existing live catalog is the export string (#17).

The script exits with 0 when it's done, and 1 when it refused. Exit 2 means it failed after it
started writing: read what it printed, which says what the live file holds now and, after `-Force`,
where the copy is.

The beta backups travel inside the file, as inert data: they are keyed by beta character GUIDs, which
live characters don't share. Live per-character files stay as they are; every character starts
fresh only on a fresh live install.

## Stress test (2026-10-19): the launch dress rehearsal

Blizzard's stress test runs on the **live** client (`_forever_`, build 1.60.1.70245), so it rehearses
day one for real (#13). 70245 is older than the beta's measured build: the addon says once at login
that it "is not the measured build", which is expected. Between the 70245 and 70450 API dumps only
voice chat, Discord, LFG, mail and a few unrelated functions changed, nothing AltStableSync calls.

Below, `<beta>` is `C:\Program Files (x86)\World of Warcraft\_classic_beta_` and `<live>` is
`C:\Program Files (x86)\World of Warcraft\_forever_`. Close every WoW client before steps 2 and 3,
and keep them closed until the step ends.

**Before the 19th, on beta:**
- Loadouts saved for the classes you'll play on the stress test (two classes if you can).
- One loadout's Share string, and your Edit Mode layout's Share string, each in a text file.
- A copy of `<beta>\WTF\Account` outside the game folder.

**On the 19th:**
1. **First launch.** Log each live WoW account in once (any character), then exit fully. Tell me:
   I read `<live>\WTF\Account` from disk (the account folders, the realm folder, the character
   folders).
2. **Transfer**, for each live account, dry run first:
   `pwsh Tools/Transfer-Profiles.ps1 -From "<beta>\WTF\Account\<id>" -To "<live>\WTF\Account\<id>" -WhatIf`
   then the same without `-WhatIf`.
3. **Deploy** the addon and the probe (#85, a ForeverProbe module; `..\ForeverProbe` must be
   checked out):
   `pwsh Tools/deploy.ps1 -AddOnsPath "<live>\Interface\AddOns"`
   `pwsh Tools/deploy-probe.ps1 -AddOnsPath "<live>\Interface\AddOns"`
4. **The launch gate, as a procedure.** On the first character: `/console scriptErrors 1`, then
   `/fp steps sync stress`, and follow the panel's buttons. It takes an **independent record** of
   the bars, macros, every bound key and the pet bar (read from the client, not from AltStableSync)
   and compares them, with its Yes/No questions, Note box and screenshots saved to disk:
   - before any Load, after the Load, and after a full exit, on two characters (the second a
     lower-level one if you can), each with Character Specific Keybindings on;
   - then a Restore of the backup that Load took on the first character, and another full exit
     (A43).

   Its first steps log AltStableSync's version, schema and catalog counts (the beta catalog should
   be there), and ask whether anything changed at login. ForeverProbe records the build,
   `WOW_PROJECT_ID`, region and locale itself. Nothing is pasted back: I read
   `AltStableSyncProbe.lua` and `ForeverProbe.lua` from disk after its last `/reload`. Steps 5
   to 7 stay by hand.
5. **Link.** Log both live accounts in at the same time. `/altsync link` on each (paste both).
   Save As a loadout on one, and check it appears in `/altsync list` on the other. After a full
   exit I check `<live>\...\AltStableSyncLink.lua` is a new store, never the beta's.
6. **Share / Import.** Import the beta loadout's Share string on a live character.
7. **Edit Mode by hand** (the section above): import your layout's string as an Account layout,
   and note which characters log in on a different layout afterwards.

**Dry run on beta first** (before the 19th): `pwsh Tools/deploy-probe.ps1`, then the same
`/fp steps sync stress` on two beta characters, to find what the procedure gets wrong while there's
time to fix it.

Paste any Lua error whole. After the session I read the SavedVariables from disk, record the results
in `docs/forever-api-notes.md` (a `## Build 70245, live client` section) and on #13.

**After the stress test.** The live `AltStableSync.lua` stays on disk, so the launch-day transfer
refuses ("already exists"). On launch day, either run it with `-Force` (it replaces the stress-test
catalog with the beta's, after keeping a verified `.pre-transfer-<time>` copy), or keep the live file
if it's the one you want. Stress-test backups are keyed by stress-test character GUIDs: inert if
Blizzard wipes the characters. Whether Blizzard's server-side keys, macros and layouts from the
stress test survive to launch is unknown.

## Nov 4 launch — day-one checklist (draft; finalised by #13)

1. **Before launch, on beta:** UI setups and loadouts saved for every class and category you play;
   the rehearsal (#13) passed; a manual copy of the beta `WTF\Account` folder kept outside the game
   directory.
2. **Live installed.** Log each live WoW account in once (any character) and **exit fully**, so
   its `WTF\Account\<id>\SavedVariables` folder exists. Then close every client.
3. For **each** live WoW account, with every WoW client closed throughout, first a dry run, then
   the real one (#12, see "Transfer" below):
   `pwsh Tools/Transfer-Profiles.ps1 -From "<beta>\WTF\Account\<id>" -To "<live>\WTF\Account\<id>" -WhatIf`
   `pwsh Tools/Transfer-Profiles.ps1 -From "<beta>\WTF\Account\<id>" -To "<live>\WTF\Account\<id>"`
   (`<beta>` = `...\_classic_beta_`, `<live>` = `...\_forever_`). If the stress test left an
   `AltStableSync.lua` there, it refuses: add `-Force` (see "After the stress test" above).
4. `pwsh Tools/deploy.ps1 -AddOnsPath "<live>\Interface\AddOns"`.
5. Log in one character. **Nothing is written.** If a UI setup exists, the addon *offers* it
   ("Make yourself at home"); beta backups stay inert (they are keyed by beta GUIDs).
6. **Launch gate:** on that character, preview and Apply the UI setup and Load one loadout. Do the
   same on a **second** character (ideally a lower-level one). **Full exit and relaunch**, then
   compare bars, macros and bindings on both against their previews. Only then load what you want
   on the other characters, one deliberate click at a time.
7. Log both WoW accounts in **at the same time** (sync needs both online): the Link addon pairs
   afresh (a new store) and later Saves flow between them. Nothing received applies until you load
   it.
