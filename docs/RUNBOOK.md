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

Load an entry on a low-level alt: the preview lists unlearned spells as skipped and leaves those
destinations untouched.

**Until #28 lands, Save is disabled**, and Save As is a fresh capture. It does **not** keep the
entries the alt couldn't load, and its preview says how many will be dropped. So don't Save As from
a low alt to "fork" a high-level loadout yet; fork from the character that has the spells.

Once #28 lands, Save (over the entry this character loaded) and Save As both keep the inherited
entries the alt couldn't load (A07–A11 in `docs/ACCEPTANCE.md`).

## Druid forms

Bars swap pages when a druid changes form. Until probe #29 has mapped which underlying slots each
form uses (active and inactive), druid form pages are reported as unavailable rather than guessed.
Changing form never saves or loads anything.

## Nov 4 launch — day-one checklist (draft; finalised by #13)

1. **Before launch, on beta:** UI setups and loadouts saved for every class and category you play;
   the rehearsal (#13) passed; a manual copy of the beta `WTF\Account` folder kept outside the game
   directory.
2. **Live installed.** Log each live WoW account in once (any character) and **exit fully**, so
   its `WTF\Account\<id>\SavedVariables` folder exists. Then close every client.
3. For **each** live WoW account:
   `pwsh Tools/Transfer-Profiles.ps1 -From "<beta>\WTF\Account\<id>" -To "<live>\WTF\Account\<id>"`
   (#12). It copies `AltStableSync.lua` only, never `AltStableSyncLink.lua`, and refuses a source that
   assigns a value to `AltStableSyncLAS` (`= nil` is fine). It also refuses when the destination
   folder is missing or a live file already exists.
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
