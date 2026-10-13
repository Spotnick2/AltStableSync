# AltStableSync

**Choose a saved setup, preview it, and load it. Save only when you want to.**

For **World of Warcraft: Forever**.

[Download on CurseForge](https://www.curseforge.com/wow/addons/altstable-sync-forever-edition) ·
[Report a bug](https://github.com/Spotnick2/AltStableSync/issues/new/choose) ·
[What's new](https://github.com/Spotnick2/AltStableSync/blob/main/CHANGELOG.md)

You spend an evening getting a character's action bars, keybindings and macros just right. Then you
log in an alt of the same class and it all starts from nothing. AltStableSync saves that setup as a
**loadout**, and loads it on any character of that class: after showing you exactly what will
change, and after taking a backup.

![The AltStableSync window](https://raw.githubusercontent.com/Spotnick2/AltStableSync/main/docs/screenshots/panel.png)

**Nothing touches your character on its own.** Not at login, not when you change zones, not when
something arrives from your other account: your bars, keys and macros change only when you confirm a
Load or a Restore in its preview. A saved loadout changes when you save it, or when your other
account saves a newer version of it (see below).

## What a loadout holds

- **Your action bars:** every bar, including the stance and form pages (druid forms, warrior
  stances, rogue stealth). Spells, items and macros.
- **Spell ranks done right.** A spell on its top rank loads as the highest rank the character
  knows. A rank you chose on purpose stays that rank.
- **Your pet bar,** one per pet family: your bear's bar isn't your cat's.
- **Your keybindings** for those bars, written to the character's own keybindings.
- **Your character macros,** created or updated to match. Account macros are never changed.

## Loading

**Load…** shows the plan first, bar by bar: what goes where, which slots empty, which keys move,
which macros are created or updated. Then:

- **A backup is taken first,** every time.
- **Each change is checked** after it's made.
- **What this character can't use yet stays empty.** A level 12 alt loading your level 60 setup
  gets what it knows. The rest of the slots stay free and fill in on a later load, once it learns
  those spells.
- **Combat stops it.** A load interrupted by combat stops cleanly. Undo it from the window, or load
  again.
- **Account keybindings?** If the character uses your account keybindings, the load first offers to
  give it its own copy, as a separate step with its own button.

## Saving

The lower half of the window is **Save this character**:

- **Save…** updates the loadout this character last loaded: the **save target**, named in the
  window. Browsing other loadouts never changes it. The review shows every slot and key that
  changes before anything is saved.
- **Save As…** makes a new loadout, in a category you pick: one per specialization of your class,
  plus General / Leveling.
- **Saving from a lower-level alt keeps what it can't see.** Spells the alt doesn't know yet stay
  in the loadout instead of being erased.

Other characters keep their own setup until they load the new version.

## Backups

Every load and restore takes a backup first. **Backups…** lists the last 10 for the character,
plus its very first. **Restore…** puts the bars and keys back as they were in the backup, and the
character macros the load changed. Macros the load created stay. Anything it can't put back (an
item no longer in your bags, a macro you've deleted since) is listed in the preview first, and left
as it is.

## Your other WoW account

The included **AltStableSync Link** addon shares your saved loadouts with your **other WoW account
on the same Battle.net account**, while both are online. They appear in its list, and nothing is
loaded on any character until you load it there. When you save a loadout on one account, the other
account's copy is updated to that version automatically; its characters keep their bars until they
load it.

If both accounts changed the same loadout, you get both versions, never a merge. Pick one with
**Manage… > Resolve…**. `/altsync link off` turns sharing off.

## Commands

| Command | What it does |
|---|---|
| `/altsync` | Open or close the window |
| `/altsync saveas <name>` | Save this character as a new loadout (General / Leveling) |
| `/altsync save` | Update the save target (reviewed first) |
| `/altsync list` | This class's loadouts, with their ids |
| `/altsync load <name or id>` | Review and load a loadout |
| `/altsync backups` | This character's backups |
| `/altsync restore [n or op]` | Review and restore a backup (default: the newest) |
| `/altsync rename <name or id> <new name>` | Rename a loadout |
| `/altsync delete <name or id>` | Delete a loadout (on both accounts) |
| `/altsync conflicts` | Loadouts both accounts changed |
| `/altsync link [on, off or refresh]` | Sharing with your other account |
| `/altsync status` | The version and what's saved |

## Good to know

- **Loadouts are per class.** A Priest's loadouts are for priests.
- **Out of combat only.** Loading, saving and restoring wait for combat to end.
- **Racial abilities aren't swapped between races.** A slot holding another race's racial is left
  for you to fill.
- **UI setups are coming.** The UI setup tab (your Edit Mode layout and UI settings) says so until
  it's ready.
- **No minimap button or key binding yet.** They're on the way; until then, `/altsync`.
- **Your loadouts are saved per WoW account**, with your backups, in
  `WTF\Account\<account>\SavedVariables\AltStableSync.lua`.

## Found a bug? Have an idea?

AltStableSync is made and tested by one person, so **your reports are how problems on other
classes and setups get found**: [open an issue](https://github.com/Spotnick2/AltStableSync/issues/new/choose).
A Lua error helps the most: turn them on with `/console scriptErrors 1`, or use BugSack. Include the
output of `/altsync status`. Ideas are welcome too.

## Credits

- **A companion to [AltStable](https://www.curseforge.com/wow/addons/altstable)**, the alt
  overview, by the same author. Each works without the other.
- **Libraries**, embedded under their own licences: LibStub, LibAccountSync-1.0 (with LibStub and
  ChatThrottleLib) and LibGlass-1.0. Their authors and licences are listed in
  [LICENSE](https://github.com/Spotnick2/AltStableSync/blob/main/LICENSE).
- **The glass** is LibGlass, the material shared by the Glass addons.

## Development

Lua 5.1 on Forever's Retail API, with no build step. `pwsh tests\run.ps1` runs the tests, and CI
runs them on every pull request, with a packaging check. The design is
[docs/DESIGN.md](https://github.com/Spotnick2/AltStableSync/blob/main/docs/DESIGN.md). The working
notes for contributors (and AI agents) are in
[AGENTS.md](https://github.com/Spotnick2/AltStableSync/blob/main/AGENTS.md).

## Licence

MIT: see [LICENSE](https://github.com/Spotnick2/AltStableSync/blob/main/LICENSE). Embedded
libraries keep their own licences.
