# Changelog

## v0.1.0

The first release, for World of Warcraft: Forever (Interface 16001).

- **Loadouts.** Save a character's action bars, keybindings, character macros and pet bars, and
  load them on any character of the same class. Every bar is included, with the stance and form
  pages. Spells on their top rank load as the highest rank the character knows. A pet bar is kept
  per pet family.
- **A preview before every change.** Load, Save, Restore, Rename and Delete each show exactly what
  will happen first, and nothing changes until you confirm. Nothing touches a character on its own:
  not at login, not on a zone change, not when a sync arrives.
- **Backups.** A backup is taken before every load and restore. Each character keeps its last 10
  and its very first. Restore puts the bars and keys back as they were, and the character macros a
  load changed; macros a load created stay, and anything that can't be put back is listed first.
- **Safe on lower-level alts.** Spells an alt can't use yet leave their slots free on a load, and
  are kept in the loadout when that alt saves.
- **Character macros** are created or updated to match the loadout. Account macros are never
  changed.
- **Keybindings** go to the character's own keybindings. A character on account keybindings is
  offered its own copy first, as a separate step.
- **Your other WoW account.** The included AltStableSync Link addon shares saved loadouts with your
  other account on the same Battle.net account, while both are online. A newer version saved on
  one account updates the other's copy (never its characters); changes made on both sides are kept
  as two versions, for you to pick from.
- **The window.** `/altsync` opens it: pick a category and a loadout, see what it holds, Load. A
  separate section saves this character to its save target, or Save As a new loadout. Backups are
  one click away.
