# Runbook

Operational notes for working on AltStableSync against a WoW: Forever client. The *why* lives in
`docs/DESIGN.md`; this is the *how*.

## Install and paths

The beta is `C:\Program Files (x86)\World of Warcraft\_classic_beta_` (executable `WowB.exe`). The
**live Forever flavour folder is not known yet** — every script takes an explicit path for it.

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

## Verifying persistence

`/reload` proves nothing about persistence — the process and its Lua state survive it. To prove a
write: **Exit Game**, wait for `WowB.exe` to go, relaunch, and check the value in game or in the
file. SavedVariables are written only on a clean logout/exit or `/reload`. **Close the client
before editing or copying any SavedVariables file**, or the client overwrites it on exit.

## When the client updates

See `.claude/skills/client-update/SKILL.md`. The API dump itself is taken from the AltStable repo.

## Full-exit proof

A claim that something persisted (a loaded loadout, a restored backup, a saved catalog entry, a
binding set) needs: note the values, **Exit Game**, wait for `WowB.exe` to go, relaunch, log the same
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
